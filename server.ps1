# 업무관리 실행기
# 같은 폴더의 HTML 파일을 http://localhost:8765 주소로 열고, 일정 알림창(깜빡이는 창)을 띄워 줍니다.
# 메모 첨부용으로 파일/폴더 선택 창을 띄우고, 첨부한 파일·폴더를 열어 줍니다.
# 실행기 7: 앱 화면이 보내 둔 일정 알림 목록을 보관해, 브라우저가 꺼져 있어도 시간이 되면 직접 알림창을 띄웁니다.
# 이 PC 안에서만 접속되며(127.0.0.1), 이 HTML 파일 하나만 보여 줍니다.
param([switch]$NoBrowser, [string]$PopupLog, [int]$Port = 8765)
$port    = $Port
$url     = "http://localhost:$port/"
$root    = $PSScriptRoot
$popup   = Join-Path $root 'popup.ps1'
$picker  = Join-Path $root 'picker.ps1'
$ocrScript = Join-Path $root 'ocr.ps1'                                   # PDF 글자 인식 일꾼 (v0.55)
$ocrDir  = Join-Path ([System.IO.Path]::GetTempPath()) 'upmu_ocr'       # 인식 결과 보관 (같은 PDF는 다시 안 함)
$allowed = @("http://localhost:$port", "http://127.0.0.1:$port")
# 실수로 프로그램이 실행되지 않도록 [열기]를 막는 확장자 (폴더에서 보기는 가능)
# 일정 알림 (실행기 7): 앱 화면이 /sched 로 보낸 앞으로 60일치 알림 목록을 PC에 보관하고 15초마다 확인
$alertDir  = Join-Path $env:LOCALAPPDATA 'upmu'
if ($Port -ne 8765) { $alertDir = Join-Path ([System.IO.Path]::GetTempPath()) "upmu_test_$Port" }   # 시험용 실행기는 실제 알림 목록을 건드리지 않음
$alertFile = Join-Path $alertDir 'alerts.json'
$firedFile = Join-Path $alertDir 'alerts_fired.json'
$LATE_MIN  = 10                                                          # 앱과 같음: 시작 후 10분까지는 늦게라도 알림
$script:alerts = @(); $script:alertOpt = @{ scale = 1; snooze = 10 }
$script:fired = New-Object 'System.Collections.Generic.HashSet[string]'
$script:lastCheck = [datetime]::MinValue
$blockedExt = '.exe .com .bat .cmd .msi .msp .ps1 .psm1 .psd1 .vbs .vbe .js .jse .wsf .wsh .scr .pif .lnk .url .reg .hta .cpl .msc .jar .dll .sys .inf .application .appref-ms .gadget .scf' -split ' '

$VERSION = 'upmu-launcher 7'
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
try { $listener.Start() }
catch {
    # 이미 실행 중: 같은 버전이면 브라우저만 열고, 예전 버전이면 끄고 새로 시작
    $running = ''
    try { $running = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "$($url)ping").Content } catch { }
    if ($running -eq $VERSION) { if (-not $NoBrowser) { Start-Process $url }; exit 0 }
    try {
        Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    } catch {
        foreach ($line in (netstat -ano | Select-String "127.0.0.1:$port\s+.*LISTENING")) { $procId = ($line.ToString().Trim() -split '\s+')[-1]; Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 800
    try { $listener.Start() } catch { if (-not $NoBrowser) { Start-Process $url }; exit 0 }
}
if (-not $NoBrowser) { Start-Process $url }

function Send-Response($stream, [string]$status, [string]$type, [byte[]]$body) {
    $head = "HTTP/1.1 $status`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length); $stream.Write($body, 0, $body.Length); $stream.Flush()
}
function Text([string]$s) { return [System.Text.Encoding]::UTF8.GetBytes($s) }

# 알림창 띄우기 (/notify · 일정 알림 공통). -PopupLog 이면 창 대신 파일에 기록 (시험용)
function Show-Popup([byte[]]$bytes) {
    if ($PopupLog) { Add-Content -LiteralPath $PopupLog -Value ([System.Text.Encoding]::UTF8.GetString($bytes)) -Encoding UTF8; return }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('upmu_popup_' + [guid]::NewGuid().ToString('N') + '.json')
    [System.IO.File]::WriteAllBytes($tmp, $bytes)
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$popup`"", '-DataFile', "`"$tmp`"")
}
# 앱의 minsText · whenText 와 같은 글자
function Mins-Text([int]$m) {
    if ($m -ge 1440 -and $m % 1440 -eq 0) { return "$($m / 1440)일" }
    if ($m -ge 60) { $h = [math]::Floor($m / 60); $r = $m % 60; if ($r) { return "$($h)시간 $($r)분" } else { return "$($h)시간" } }
    return "$($m)분"
}
function When-Text([int]$mins) {
    if ($mins -gt 0) { return "$(Mins-Text $mins) 후 시작" }
    if ($mins -eq 0) { return '지금 시작' }
    return "$(Mins-Text (-$mins)) 전 시작됨"
}
function Load-Alerts {
    try {
        if (Test-Path -LiteralPath $alertFile) {
            $d = [System.IO.File]::ReadAllText($alertFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $script:alerts = @($d.alerts)
            if ($d.scale) { $script:alertOpt.scale = [double]$d.scale }; if ($d.snooze) { $script:alertOpt.snooze = [int]$d.snooze }
        }
    } catch { }
    try { if (Test-Path -LiteralPath $firedFile) { foreach ($k in @([System.IO.File]::ReadAllText($firedFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)) { [void]$script:fired.Add([string]$k) } } } catch { }
}
function Save-Fired {
    $cut = (Get-Date).AddDays(-3).ToString('yyyy-MM-dd')                 # 3일 지난 기록은 정리 (키 = 일정id|회차날짜|시작|알림분)
    $keep = @($script:fired | Where-Object { $p = $_.Split('|'); $p.Length -lt 2 -or $p[1] -ge $cut })
    $script:fired = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($k in $keep) { [void]$script:fired.Add($k) }
    try { if (-not (Test-Path -LiteralPath $alertDir)) { New-Item -ItemType Directory -Path $alertDir | Out-Null }; [System.IO.File]::WriteAllText($firedFile, (ConvertTo-Json @($keep) -Compress), [System.Text.Encoding]::UTF8) } catch { }
}
function Check-Alerts {
    if (((Get-Date) - $script:lastCheck).TotalSeconds -lt 15) { return }
    $script:lastCheck = Get-Date
    if (-not $script:alerts.Count) { return }
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds(); $changed = $false
    foreach ($a in $script:alerts) {
        $key = [string]$a.key
        if (-not $key -or $script:fired.Contains($key)) { continue }
        $at = [double]$a.at; $start = [double]$a.start
        if ($now -ge $at -and $now -lt $start + $LATE_MIN * 60000) {
            $diff = $start - $now
            $mins = if ($diff -gt 0) { [int][math]::Ceiling($diff / 60000) } else { - [int][math]::Floor(- $diff / 60000) }
            $payload = @{ head = "$(When-Text $mins) · $([string]$a.kind)"; title = [string]$a.title; body = [string]$a.body; scale = $script:alertOpt.scale; snooze = $script:alertOpt.snooze } | ConvertTo-Json -Compress
            [void]$script:fired.Add($key); $changed = $true
            try { Show-Popup ([System.Text.Encoding]::UTF8.GetBytes($payload)) } catch { }
        }
    }
    if ($changed) { Save-Fired }
}

# 요청 본문(base64) → 바이트. 잘못되면 $null
function Read-Body($reader, $headers, [int]$max = 40000) {
    $len = 0; [void][int]::TryParse([string]$headers['content-length'], [ref]$len)
    if ($len -le 0 -or $len -gt $max) { return $null }
    $buf = New-Object char[] $len; $got = 0
    while ($got -lt $len) { $n = $reader.Read($buf, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
    try { return , [Convert]::FromBase64String((New-Object string($buf, 0, $got))) } catch { return $null }
}

# 첨부 열기: 'ok' | 'notfound' | 'blocked' | 'bad'
function Open-Target([string]$p, [string]$mode) {
    if (-not $p -or $p.Length -gt 1000) { return 'bad' }
    # 로컬 드라이브(C:\...) 또는 네트워크 경로(\\서버\...)만. 장치 경로(\\?\, \\.\), 대체 스트림(:), 특수문자, 끝의 점·공백 금지
    if ($p -notmatch '^([A-Za-z]:\\|\\\\[^\\?.][^\\]*\\)') { return 'bad' }
    if ($p.Substring(2).Contains(':') -or $p -match '[*?"<>|\x00-\x1f]' -or $p -match '[. ]$') { return 'bad' }
    if (-not (Test-Path -LiteralPath $p)) { return 'notfound' }
    $isDir = Test-Path -LiteralPath $p -PathType Container
    if ($mode -eq 'reveal') {
        # 상위 폴더를 열고 그 항목을 선택해 둠
        [void][System.Diagnostics.Process]::Start('explorer.exe', "/select,`"$p`""); return 'ok'
    }
    if ($isDir) { [void][System.Diagnostics.Process]::Start('explorer.exe', "`"$p`""); return 'ok' }
    if ($blockedExt -contains [System.IO.Path]::GetExtension($p).ToLower()) { return 'blocked' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo $p
    $psi.UseShellExecute = $true                           # 기본 프로그램으로 열기 (엑셀 → 엑셀)
    $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($p)
    [void][System.Diagnostics.Process]::Start($psi)
    return 'ok'
}

Load-Alerts
while ($true) {
    # 연결을 기다리는 동안 일정 알림 확인 (브라우저가 꺼져 있어도 알림)
    if (-not $listener.Pending()) { try { Check-Alerts } catch { }; Start-Sleep -Milliseconds 200; continue }
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        # 브라우저가 미리 열어 두고 요청을 안 보내는 연결 때문에 서버 전체가 멈추지 않도록 시간 제한
        $stream.ReadTimeout = 3000; $stream.WriteTimeout = 3000
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 8192, $true)
        $requestLine = $reader.ReadLine()
        $headers = @{}
        while ($true) {
            $l = $reader.ReadLine()
            if ($l -eq $null -or $l -eq '') { break }
            $i = $l.IndexOf(':'); if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLower()] = $l.Substring($i + 1).Trim() }
        }
        $method = 'GET'; $path = '/'; $query = @{}
        if ($requestLine) {
            $parts = $requestLine.Split(' ')
            if ($parts.Length -ge 2) {
                $method = $parts[0]; $pq = $parts[1].Split('?'); $path = $pq[0]
                if ($pq.Length -gt 1) { foreach ($kv in $pq[1].Split('&')) { $e = $kv.IndexOf('='); if ($e -gt 0) { $query[$kv.Substring(0, $e)] = [Uri]::UnescapeDataString($kv.Substring($e + 1)) } } }
            }
        }

        if ($method -eq 'GET' -and $path -eq '/ping') {
            Send-Response $stream '200 OK' 'text/plain; charset=utf-8' (Text $VERSION)
        }
        elseif ($method -eq 'POST' -and $path -eq '/notify') {
            # 이 프로그램 화면에서 보낸 요청만 받음
            if ($allowed -notcontains $headers['origin']) { Send-Response $stream '403 Forbidden' 'text/plain' (Text 'forbidden'); continue }
            $len = 0; [void][int]::TryParse([string]$headers['content-length'], [ref]$len)
            if ($len -le 0 -or $len -gt 40000) { Send-Response $stream '400 Bad Request' 'text/plain' (Text 'bad'); continue }
            $buf = New-Object char[] $len; $got = 0
            while ($got -lt $len) { $n = $reader.Read($buf, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
            try { $bytes = [Convert]::FromBase64String((New-Object string($buf, 0, $got))) }
            catch { Send-Response $stream '400 Bad Request' 'text/plain' (Text 'bad'); continue }
            Show-Popup $bytes
            Send-Response $stream '200 OK' 'text/plain; charset=utf-8' (Text 'ok')
        }
        elseif ($method -eq 'POST' -and $path -eq '/sched') {
            # 일정 알림 목록 받기 (실행기 7): { alerts:[{key, at, start, kind, title, body}], fired:[키], scale, snooze } → PC에 보관
            if ($allowed -notcontains $headers['origin']) { Send-Response $stream '403 Forbidden' 'text/plain' (Text 'forbidden'); continue }
            $stream.ReadTimeout = 10000
            $bytes = Read-Body $reader $headers 4000000
            $d = $null; if ($bytes) { try { $d = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json } catch { } }
            if (-not $d) { Send-Response $stream '400 Bad Request' 'text/plain' (Text 'bad'); continue }
            $script:alerts = @($d.alerts)
            if ($d.scale) { $script:alertOpt.scale = [double]$d.scale }; if ($d.snooze) { $script:alertOpt.snooze = [int]$d.snooze }
            foreach ($k in @($d.fired)) { if ($k) { [void]$script:fired.Add([string]$k) } }
            try { if (-not (Test-Path -LiteralPath $alertDir)) { New-Item -ItemType Directory -Path $alertDir | Out-Null }; [System.IO.File]::WriteAllBytes($alertFile, $bytes) } catch { }
            Save-Fired
            $script:lastCheck = [datetime]::MinValue                            # 받자마자 한 번 확인
            Send-Response $stream '200 OK' 'application/json; charset=utf-8' (Text (@{ ok = $true; count = $script:alerts.Count; fired = @($script:fired) } | ConvertTo-Json -Compress))
        }
        elseif ($method -eq 'POST' -and ($path -eq '/pick' -or $path -eq '/open')) {
            # 메모 첨부: 이 프로그램 화면에서 보낸 요청만 받음
            if ($allowed -notcontains $headers['origin']) { Send-Response $stream '403 Forbidden' 'text/plain' (Text 'forbidden'); continue }
            $bytes = Read-Body $reader $headers
            $req = $null
            if ($bytes) { try { $req = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json } catch { } }
            if (-not $req) { Send-Response $stream '400 Bad Request' 'text/plain' (Text 'bad'); continue }
            if ($path -eq '/pick') {
                # 선택 창은 별도 창(STA)으로 띄우고, 고를 때까지 기다림
                $kind = if ($req.kind -eq 'folder') { 'folder' } else { 'file' }
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('upmu_pick_' + [guid]::NewGuid().ToString('N') + '.txt')
                $exe = (Get-Process -Id $PID).Path
                Start-Process -FilePath $exe -WindowStyle Hidden -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$picker`"", '-Kind', $kind, '-OutFile', "`"$tmp`"")
                $picked = ''
                if (Test-Path -LiteralPath $tmp) { $picked = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8); Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
                Send-Response $stream '200 OK' 'application/json; charset=utf-8' (Text (@{ kind = $kind; path = $picked.Trim() } | ConvertTo-Json -Compress))
            } else {
                $res = 'bad'; try { $res = Open-Target ([string]$req.path) ([string]$req.mode) } catch { }
                Send-Response $stream '200 OK' 'text/plain; charset=utf-8' (Text $res)
            }
        }
        elseif ($method -eq 'POST' -and $path -eq '/ocr/start') {
            # PDF 글자 인식 시작: 본문 = PDF(base64, 최대 약 15MB). 같은 파일(SHA-256)은 이미 한 결과를 씀
            if ($allowed -notcontains $headers['origin']) { Send-Response $stream '403 Forbidden' 'text/plain' (Text 'forbidden'); continue }
            $stream.ReadTimeout = 30000
            $bytes = Read-Body $reader $headers 21000000
            if (-not $bytes -or $bytes.Length -lt 5 -or [System.Text.Encoding]::ASCII.GetString($bytes, 0, 5) -ne '%PDF-') { Send-Response $stream '400 Bad Request' 'text/plain' (Text 'bad'); continue }
            if (-not (Test-Path -LiteralPath $ocrDir)) { New-Item -ItemType Directory -Path $ocrDir | Out-Null }
            $sha = [System.Security.Cryptography.SHA256]::Create(); $id = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower(); $sha.Dispose()
            $base = Join-Path $ocrDir $id
            if (-not (Test-Path -LiteralPath "$base.pdf")) { [System.IO.File]::WriteAllBytes("$base.pdf", $bytes) }
            $done = Test-Path -LiteralPath "$base.done"
            if (-not $done) {
                Remove-Item -LiteralPath "$base.err" -ErrorAction SilentlyContinue
                $running = $false
                if (Test-Path -LiteralPath "$base.lock") { try { $running = (Get-Process -Id ([int][System.IO.File]::ReadAllText("$base.lock")) -ErrorAction Stop) -ne $null } catch { $running = $false } }
                if (-not $running) {
                    $exe = (Get-Process -Id $PID).Path
                    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ocrScript`"", '-Pdf', "`"$base.pdf`"", '-Out', "`"$base`"")
                }
            }
            Send-Response $stream '200 OK' 'application/json; charset=utf-8' (Text ('{"id":"' + $id + '","done":' + $done.ToString().ToLower() + '}'))
        }
        elseif ($method -eq 'GET' -and $path -eq '/ocr/result') {
            # 인식 결과: ?id=…&from=N → N쪽부터 지금까지 된 쪽들
            $id = [string]$query['id']; $from = 1; [void][int]::TryParse([string]$query['from'], [ref]$from)
            if ($id -notmatch '^[0-9a-f]{64}$') { Send-Response $stream '400 Bad Request' 'text/plain' (Text 'bad'); continue }
            $base = Join-Path $ocrDir $id
            $total = 0; if (Test-Path -LiteralPath "$base.meta") { try { $total = [int](([System.IO.File]::ReadAllText("$base.meta") | ConvertFrom-Json).total) } catch { } }
            $err = ''; if (Test-Path -LiteralPath "$base.err") { $err = [System.IO.File]::ReadAllText("$base.err", [System.Text.Encoding]::UTF8) }
            $done = Test-Path -LiteralPath "$base.done"
            $running = $false
            if (Test-Path -LiteralPath "$base.lock") { try { $running = (Get-Process -Id ([int][System.IO.File]::ReadAllText("$base.lock")) -ErrorAction Stop) -ne $null } catch { $running = $false } }
            $pages = @()
            if (Test-Path -LiteralPath "$base.jsonl") {
                $rfs = New-Object System.IO.FileStream("$base.jsonl", [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)   # 일꾼이 쓰는 중에도 읽기
                $rsr = New-Object System.IO.StreamReader($rfs, [System.Text.Encoding]::UTF8); $all = @($rsr.ReadToEnd().Split("`n") | Where-Object { $_.Trim() }); $rsr.Close()
                if ($from -lt 1) { $from = 1 }
                if ($all.Count -ge $from) { $pages = $all[($from - 1)..($all.Count - 1)] }
            }
            $errJson = '"' + $err.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", ' ') + '"'
            $body = '{"done":' + $done.ToString().ToLower() + ',"running":' + $running.ToString().ToLower() + ',"total":' + $total + ',"from":' + $from + ',"err":' + $errJson + ',"pages":[' + ($pages -join ',') + ']}'
            Send-Response $stream '200 OK' 'application/json; charset=utf-8' (Text $body)
        }
        elseif ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
            # 가장 최근에 저장된 HTML 파일을 매번 새로 읽음 (파일을 바꾸면 새로고침만 하면 됨)
            $html = Get-ChildItem -LiteralPath $root -Filter '*.html' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($html) { Send-Response $stream '200 OK' 'text/html; charset=utf-8' ([System.IO.File]::ReadAllBytes($html.FullName)) }
            else { Send-Response $stream '404 Not Found' 'text/plain; charset=utf-8' (Text 'HTML 파일이 없습니다') }
        }
        else {
            Send-Response $stream '404 Not Found' 'text/plain; charset=utf-8' (Text 'Not found')
        }
    } catch { } finally { $client.Close() }
}
