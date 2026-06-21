# keeper.ps1 — 检测断网并自动登录上网认证（支持深澜 Srun 门户，如杭电 login.hdu.edu.cn）
# 用法:
#   powershell -File keeper.ps1              常驻运行，每隔一段时间检测一次
#   powershell -File keeper.ps1 -Once        只检测/登录一次就退出
#   powershell -File keeper.ps1 -TestLogin   不管当前是否在线，强制发一次登录请求（用于验证配置）

param(
    [switch]$Once,
    [switch]$TestLogin,
    [switch]$Watchdog
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath  = Join-Path $scriptDir 'config.json'
$logPath     = Join-Path $scriptDir '运行日志.txt'
$heartbeatPath = Join-Path $scriptDir '最近检测.txt'

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try {
        if ((Test-Path $logPath) -and ((Get-Item $logPath).Length -gt 2MB)) {
            Remove-Item $logPath -Force -Confirm:$false
        }
        Add-Content -Path $logPath -Value $line -Encoding UTF8
    } catch {}
}

# 心跳文件每次检测都覆盖写入，永远只有一行，用来一眼确认脚本还活着、最近一次检测的结果
function Write-Heartbeat {
    param([string]$State, [string]$Source)
    $human = switch ($State) { 'Online' { '网络正常' } 'Portal' { '被认证页拦截' } default { '网络不通' } }
    $line = "最后检测: {0}  状态: {1}  ({2})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $human, $Source
    try { Set-Content -Path $heartbeatPath -Value $line -Encoding UTF8 } catch {}
}

if (-not (Test-Path $configPath)) {
    Write-Log "找不到配置文件 config.json，请确认它和 keeper.ps1 在同一个文件夹里。"
    exit 1
}

try {
    $cfg = Get-Content -Raw -Encoding UTF8 -Path $configPath | ConvertFrom-Json
} catch {
    Write-Log ("config.json 格式有误，无法解析: " + $_.Exception.Message)
    exit 1
}

# 账号或密码还是占位符时，只检测网络、不尝试登录
$configReady = ($cfg.username -notlike '*在这里填*') -and ($cfg.password -notlike '*在这里填*')
if ($cfg.portal_type -ne 'srun') {
    $configReady = $configReady -and ($cfg.login.url -notlike '*在这里填*')
}

# ============================================================
# 联网状态检测
#   Online  - 能正常上外网
#   Portal  - 请求被认证页面拦截/重定向（需要登录）
#   Offline - 完全不通（网线没插、没拿到 IP 等）
# ============================================================
function Test-Internet {
    $info = @{ State = 'Offline'; RedirectUrl = $null; Detail = '' }
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create([string]$cfg.check.probe_url)
        $req.AllowAutoRedirect = $false
        $req.Timeout = [int]$cfg.check.timeout_seconds * 1000
        $req.ReadWriteTimeout = $req.Timeout
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        $resp = $req.GetResponse()
        $status = [int]$resp.StatusCode
        if ($status -eq 204) {
            $info.State = 'Online'
        } elseif (($status -ge 300) -and ($status -lt 400)) {
            $info.State = 'Portal'
            $info.RedirectUrl = $resp.Headers['Location']
        } else {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Close()
            if ($body.Trim() -eq [string]$cfg.check.expected_content) {
                $info.State = 'Online'
            } else {
                $info.State = 'Portal'
                if ($body -match '(?i)(?:url\s*=\s*|location\.href\s*=\s*[''"])(http[^''"<>\s]+)') {
                    $info.RedirectUrl = $Matches[1]
                }
            }
        }
    } catch [System.Net.WebException] {
        $eResp = $_.Exception.Response
        if ($null -ne $eResp) {
            $info.State = 'Portal'
            $info.RedirectUrl = $eResp.Headers['Location']
            $info.Detail = $_.Exception.Message
            $eResp.Close()
        } else {
            $info.Detail = $_.Exception.Message
        }
    } catch {
        $info.Detail = $_.Exception.Message
    } finally {
        if ($null -ne $resp) { $resp.Close() }
    }
    return $info
}

# ============================================================
# 深澜 (Srun) 门户登录算法
# 流程: get_challenge 拿 token -> XXTEA 加密用户信息 -> HMAC-MD5 密码
#       -> SHA1 签名 -> 请求 /cgi-bin/srun_portal 登录
# ============================================================

# 把字节数组按小端序打包成 32 位无符号整数数组（深澜 JS 里的 s 函数）
function ConvertTo-SrunUIntList {
    param([byte[]]$Bytes, [bool]$IncludeLength)
    $c = $Bytes.Length
    $v = New-Object 'System.Collections.Generic.List[uint64]'
    for ($i = 0; $i -lt $c; $i += 4) {
        $val = [uint64]0
        for ($j = 0; $j -lt 4; $j++) {
            if (($i + $j) -lt $c) { $val = $val -bor ([uint64]$Bytes[$i + $j] -shl (8 * $j)) }
        }
        $v.Add($val)
    }
    if ($IncludeLength) { $v.Add([uint64]$c) }
    return ,$v
}

# 深澜定制版 XXTEA 加密（JS 里的 xEncode），所有运算按 32 位无符号取模
function Invoke-SrunXEncode {
    param([byte[]]$Data, [byte[]]$Key)
    # 注意: PowerShell 变量名大小写不敏感，掩码不能叫 $M（会和循环里的 $m 撞名）
    $mask = [uint64]0xFFFFFFFFL
    $v = ConvertTo-SrunUIntList -Bytes $Data -IncludeLength $true
    $k = ConvertTo-SrunUIntList -Bytes $Key  -IncludeLength $false
    while ($k.Count -lt 4) { $k.Add([uint64]0) }

    $n = $v.Count - 1
    $z = $v[$n]
    $y = $v[0]
    $delta = [uint64]0x9E3779B9L
    $q = [int][Math]::Floor(6 + 52 / ($n + 1))
    $d = [uint64]0

    while ($q -gt 0) {
        $q--
        $d = ($d + $delta) -band $mask
        $e = [int](($d -shr 2) -band 3)
        for ($p = 0; $p -lt $n; $p++) {
            $y = $v[$p + 1]
            $m = (($z -shr 5) -bxor (($y -shl 2) -band $mask)) -band $mask
            $m = ($m + (((($y -shr 3) -bxor (($z -shl 4) -band $mask)) -bxor ($d -bxor $y)) -band $mask)) -band $mask
            $m = ($m + (($k[($p -band 3) -bxor $e] -bxor $z) -band $mask)) -band $mask
            $v[$p] = ($v[$p] + $m) -band $mask
            $z = $v[$p]
        }
        $y = $v[0]
        $m = (($z -shr 5) -bxor (($y -shl 2) -band $mask)) -band $mask
        $m = ($m + (((($y -shr 3) -bxor (($z -shl 4) -band $mask)) -bxor ($d -bxor $y)) -band $mask)) -band $mask
        $m = ($m + (($k[($p -band 3) -bxor $e] -bxor $z) -band $mask)) -band $mask
        $v[$n] = ($v[$n] + $m) -band $mask
        $z = $v[$n]
    }

    $out = New-Object byte[] ($v.Count * 4)
    for ($i = 0; $i -lt $v.Count; $i++) {
        $out[$i * 4]     = [byte]($v[$i] -band 0xFF)
        $out[$i * 4 + 1] = [byte](($v[$i] -shr 8) -band 0xFF)
        $out[$i * 4 + 2] = [byte](($v[$i] -shr 16) -band 0xFF)
        $out[$i * 4 + 3] = [byte](($v[$i] -shr 24) -band 0xFF)
    }
    return ,$out
}

# 深澜定制字母表的 Base64
function ConvertTo-SrunBase64 {
    param([byte[]]$Bytes)
    $alpha = 'LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA'
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Bytes.Length; $i += 3) {
        $b0 = [int]$Bytes[$i]
        $hasB1 = ($i + 1) -lt $Bytes.Length
        $hasB2 = ($i + 2) -lt $Bytes.Length
        $b1 = 0; $b2 = 0
        if ($hasB1) { $b1 = [int]$Bytes[$i + 1] }
        if ($hasB2) { $b2 = [int]$Bytes[$i + 2] }
        $triple = ($b0 -shl 16) -bor ($b1 -shl 8) -bor $b2
        [void]$sb.Append($alpha[($triple -shr 18) -band 63])
        [void]$sb.Append($alpha[($triple -shr 12) -band 63])
        if ($hasB1) { [void]$sb.Append($alpha[($triple -shr 6) -band 63]) } else { [void]$sb.Append('=') }
        if ($hasB2) { [void]$sb.Append($alpha[$triple -band 63]) } else { [void]$sb.Append('=') }
    }
    return $sb.ToString()
}

function Get-HmacMd5Hex {
    param([string]$Key, [string]$Message)
    $h = New-Object System.Security.Cryptography.HMACMD5 (,[Text.Encoding]::UTF8.GetBytes($Key))
    return (($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Message)) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-Sha1Hex {
    param([string]$Text)
    $h = [System.Security.Cryptography.SHA1]::Create()
    return (($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertTo-JsonStringEscape {
    param([string]$Text)
    return $Text.Replace('\', '\\').Replace('"', '\"')
}

function Invoke-SrunLogin {
    param([string]$RedirectUrl)

    $base = ([string]$cfg.srun.base_url).TrimEnd('/')
    $user = [string]$cfg.username
    $pass = [string]$cfg.password
    $n    = [string]$cfg.srun.n
    $type = [string]$cfg.srun.type

    # ac_id 优先从认证页跳转地址里取，取不到用配置值。
    # 杭电门户跳转地址形如 https://login.hdu.edu.cn/index_0.html，ac_id 编码在文件名里
    # （index_<acid>.html），浏览器也是据此决定 ac_id；所以两种写法都要认：
    #   1) 查询串 ?ac_id=数字   2) 文件名 index_数字.html
    $acid = [string]$cfg.srun.ac_id
    if ($RedirectUrl) {
        if     ($RedirectUrl -match '(?i)ac_id=(\d+)')       { $acid = $Matches[1] }
        elseif ($RedirectUrl -match '(?i)index_(\d+)\.html') { $acid = $Matches[1] }
    }

    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $cb = 'jQuery112404953340710317085_' + $ts

    # 第 1 步: 获取 challenge token
    try {
        $chalUrl = '{0}/cgi-bin/get_challenge?callback={1}&username={2}&ip=&_={3}' -f $base, $cb, [Uri]::EscapeDataString($user), $ts
        $chalResp = Invoke-WebRequest -Uri $chalUrl -UseBasicParsing -TimeoutSec 10
        $chalText = [string]$chalResp.Content
    } catch {
        Write-Log ("获取 challenge 失败: " + $_.Exception.Message)
        return $false
    }

    $mTok = [regex]::Match($chalText, '"challenge"\s*:\s*"([^"]+)"')
    if (-not $mTok.Success) { $mTok = [regex]::Match($chalText, '"token"\s*:\s*"([^"]+)"') }
    if (-not $mTok.Success) {
        $short = ($chalText -replace '\s+', ' ').Trim()
        if ($short.Length -gt 200) { $short = $short.Substring(0, 200) + '...' }
        Write-Log ("challenge 响应里没有 token，原始响应: " + $short)
        return $false
    }
    $token = $mTok.Groups[1].Value

    $ip = ''
    $mIp = [regex]::Match($chalText, '"client_ip"\s*:\s*"([^"]+)"')
    if ($mIp.Success) { $ip = $mIp.Groups[1].Value }

    # 第 2 步: 构造加密参数
    $infoJson = '{{"username":"{0}","password":"{1}","ip":"{2}","acid":"{3}","enc_ver":"srun_bx1"}}' -f `
        (ConvertTo-JsonStringEscape $user), (ConvertTo-JsonStringEscape $pass), $ip, $acid

    $tokenBytes = [Text.Encoding]::UTF8.GetBytes($token)
    $infoBytes  = [Text.Encoding]::UTF8.GetBytes($infoJson)
    $encrypted  = Invoke-SrunXEncode -Data $infoBytes -Key $tokenBytes
    $i = '{SRBX1}' + (ConvertTo-SrunBase64 -Bytes $encrypted)

    $hmd5 = Get-HmacMd5Hex -Key $token -Message $pass
    $chkStr = $token + $user + $token + $hmd5 + $token + $acid + $token + $ip + $token + $n + $token + $type + $token + $i
    $chksum = Get-Sha1Hex -Text $chkStr

    # 第 3 步: 发送登录请求
    $ts2 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $pairs = [ordered]@{
        callback     = $cb
        action       = 'login'
        username     = $user
        password     = '{MD5}' + $hmd5
        os           = [string]$cfg.srun.os
        name         = [string]$cfg.srun.name
        double_stack = [string]$cfg.srun.double_stack
        chksum       = $chksum
        info         = $i
        ac_id        = $acid
        ip           = $ip
        n            = $n
        type         = $type
        captchaVal   = ''
        '_'          = $ts2
    }
    $qs = (($pairs.GetEnumerator() | ForEach-Object { $_.Key + '=' + [Uri]::EscapeDataString([string]$_.Value) }) -join '&')
    $loginUrl = $base + '/cgi-bin/srun_portal?' + $qs

    try {
        $resp = Invoke-WebRequest -Uri $loginUrl -UseBasicParsing -TimeoutSec 15
        $text = [string]$resp.Content
    } catch {
        Write-Log ("发送登录请求失败: " + $_.Exception.Message)
        return $false
    }

    $short = ($text -replace '\s+', ' ').Trim()
    if ($short.Length -gt 300) { $short = $short.Substring(0, 300) + '...' }
    Write-Log ("登录响应: " + $short)

    if ($text -match '"error"\s*:\s*"ok"') { return $true }
    if ($text -match 'ip_already_online_error') {
        Write-Log "服务器提示该 IP 已在线，视为登录成功。"
        return $true
    }
    return $false
}

# ============================================================
# 通用门户登录（非深澜，直接按 config 里的模板发请求）
# ============================================================
function Invoke-PortalLogin {
    param([string]$RedirectUrl)

    $u = [Uri]::EscapeDataString([string]$cfg.username)
    $p = [Uri]::EscapeDataString([string]$cfg.password)
    $body = [string]$cfg.login.body_template
    $body = $body.Replace('{username}', $u).Replace('{password}', $p)

    if ($body.Contains('{queryString}')) {
        $qs = ''
        if ($RedirectUrl) {
            $i = $RedirectUrl.IndexOf('?')
            if ($i -ge 0) { $qs = [Uri]::EscapeDataString($RedirectUrl.Substring($i + 1)) }
        }
        $body = $body.Replace('{queryString}', $qs)
    }

    try {
        $resp = Invoke-WebRequest -Uri ([string]$cfg.login.url) -Method ([string]$cfg.login.method) `
            -Body $body -ContentType ([string]$cfg.login.content_type) -UseBasicParsing -TimeoutSec 15
        $text = [string]$resp.Content
        $short = ($text -replace '\s+', ' ').Trim()
        if ($short.Length -gt 300) { $short = $short.Substring(0, 300) + '...' }
        Write-Log ("已发送登录请求，服务器响应: " + $short)
        $kw = [string]$cfg.login.success_keyword
        if ($kw -ne '') { return $text.Contains($kw) }
        return $true
    } catch {
        Write-Log ("发送登录请求失败: " + $_.Exception.Message)
        return $false
    }
}

function Invoke-Login {
    param([string]$RedirectUrl)
    if ($cfg.portal_type -eq 'srun') { return (Invoke-SrunLogin -RedirectUrl $RedirectUrl) }
    return (Invoke-PortalLogin -RedirectUrl $RedirectUrl)
}

# ============================================================
# 主流程
# ============================================================

if ($TestLogin) {
    if (-not $configReady) {
        Write-Log "config.json 里的账号或密码还没填，无法测试登录。"
        exit 1
    }
    Write-Log "开始登录测试（不管当前是否在线，强制发一次登录请求）..."
    $null = Invoke-Login
    Start-Sleep -Seconds 2
    $net = Test-Internet
    Write-Log ("登录测试结束，当前网络状态: " + $net.State)
    exit 0
}

# 看门狗模式：独立进程，由计划任务每隔几分钟跑一次。
# 在线时只更新心跳、不写日志（保持日志干净）；不在线时才登录并记日志。
# 它和常驻主进程互相独立，万一主进程卡死/退出，看门狗仍能把网络救回来。
if ($Watchdog) {
    $net = Test-Internet
    Write-Heartbeat -State $net.State -Source '看门狗'
    if (($net.State -ne 'Online') -and $configReady) {
        Write-Log "（看门狗）检测到掉线，尝试登录..."
        $null = Invoke-Login -RedirectUrl $net.RedirectUrl
        Start-Sleep -Seconds 3
        $verify = Test-Internet
        Write-Heartbeat -State $verify.State -Source '看门狗'
        if ($verify.State -eq 'Online') { Write-Log "（看门狗）登录成功，网络已恢复。" }
        else { Write-Log "（看门狗）登录后网络仍未恢复。" }
    }
    exit 0
}

Write-Log ("脚本启动（每 {0} 秒检测一次，探测地址 {1}）" -f $cfg.check.interval_seconds, $cfg.check.probe_url)
if (-not $configReady) {
    Write-Log "提示: config.json 还没填账号或密码，目前只检测网络、不会自动登录。"
}

$lastState = ''
$failCount = 0

while ($true) {
    $net = Test-Internet
    $state = $net.State
    Write-Heartbeat -State $state -Source '常驻进程'

    if ($state -eq 'Online') {
        if ($lastState -ne 'Online') { Write-Log "网络正常。" }
        $failCount = 0
    }
    else {
        if ($state -eq 'Portal') {
            Write-Log "检测到被认证页面拦截，需要登录。"
            if ($net.RedirectUrl) { Write-Log ("认证页面地址: " + $net.RedirectUrl) }
        } else {
            Write-Log ("网络不通（可能没插网线/没拿到 IP）: " + $net.Detail)
        }

        if ($configReady) {
            $null = Invoke-Login -RedirectUrl $net.RedirectUrl
            Start-Sleep -Seconds 3
            $verify = Test-Internet
            if ($verify.State -eq 'Online') {
                Write-Log "登录成功，网络已恢复。"
                $state = 'Online'
                $failCount = 0
            } else {
                $failCount++
                Write-Log ("登录后网络仍未恢复（连续第 {0} 次失败）。" -f $failCount)
                if ($failCount -ge [int]$cfg.retry.max_attempts) {
                    Write-Log ("连续失败 {0} 次，暂停 {1} 秒后再试，避免频繁请求认证服务器。" -f $failCount, $cfg.retry.cooldown_seconds)
                    if (-not $Once) { Start-Sleep -Seconds ([int]$cfg.retry.cooldown_seconds) }
                    $failCount = 0
                }
            }
        } else {
            Write-Log "未配置账号，跳过自动登录。请按 README.md 填写 config.json。"
        }
    }

    $lastState = $state
    if ($Once) { break }
    Start-Sleep -Seconds ([int]$cfg.check.interval_seconds)
}
