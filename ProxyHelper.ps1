#requires -Version 5.1
# UTF-8 with BOM is required for Chinese text in Windows PowerShell 5.1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigDirectory {
    if ($env:CODEX_HOME) { return [IO.Path]::GetFullPath($env:CODEX_HOME) }
    return (Join-Path $env:USERPROFILE '.codex')
}

function Assert-SafeDirectory([string]$Directory) {
    if (-not [IO.Path]::IsPathRooted($Directory)) { throw '配置目录必须是绝对路径。' }
    $item = Get-Item -LiteralPath $Directory -Force
    if (-not $item.PSIsContainer) { throw '配置目录不存在。请先安装并运行客户端一次。' }
    $current = $item
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '此版本不自动修改符号链接或目录联接中的配置，请手动配置。'
        }
        $current = $current.Parent
    }
    $target = Join-Path $Directory '.env'
    if (Test-Path -LiteralPath $target) {
        $file = Get-Item -LiteralPath $target -Force
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '.env 不是普通文件，已停止。'
        }
    }
}

function Get-ByteHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-EnvState([string]$Directory) {
    Assert-SafeDirectory $Directory
    $target = Join-Path $Directory '.env'
    $exists = Test-Path -LiteralPath $target
    [byte[]]$bytes = @()
    if ($exists) { $bytes = [IO.File]::ReadAllBytes($target) }
    if ($bytes.Length -gt 1048576) { throw '.env 超过 1 MB，已停止自动编辑。' }
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    $offset = 0
    if ($bom) { $offset = 3 }
    try { $content = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset) }
    catch { throw '.env 不是有效 UTF-8 文件，已停止。请先手动检查编码。' }
    if ($content.Contains([string][char]0)) { throw '.env 含有空字符，可能是 UTF-16 文件，已停止。' }
    return [pscustomobject]@{ Exists=$exists; Bytes=$bytes; Text=$content; Bom=$bom; Hash=(Get-ByteHash $bytes) }
}

function Get-LocalProxy([string]$Value) {
    $value = $Value.Trim()
    if ($value -match '^\d+$') { $value = 'http://127.0.0.1:' + $value }
    elseif ($value -notmatch '://') { $value = 'http://' + $value }
    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) { throw '请输入端口号或 http://127.0.0.1:端口。' }
    $address = $null
    $isV6Loopback = [Net.IPAddress]::TryParse($uri.Host.Trim('[',']'), [ref]$address) -and
        $address.Equals([Net.IPAddress]::IPv6Loopback)
    if ($uri.Scheme -ne 'http' -or ($uri.Host -notin @('localhost','127.0.0.1') -and -not $isV6Loopback) -or
        $uri.Port -lt 1 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
        throw '本版本仅支持无账号密码的本机 HTTP/Mixed 代理，例如 http://127.0.0.1:7897。'
    }
    $proxyHost = $uri.Host
    if ($isV6Loopback) { $proxyHost = '[::1]' }
    return ('http://{0}:{1}' -f $proxyHost, $uri.Port)
}

function Test-ProxyTunnel([string]$Proxy, [int]$TimeoutMs = 2500) {
    $uri = [Uri](Get-LocalProxy $Proxy)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($uri.DnsSafeHost, $uri.Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs
        $request = [Text.Encoding]::ASCII.GetBytes("CONNECT chatgpt.com:443 HTTP/1.1`r`nHost: chatgpt.com:443`r`n`r`n")
        $stream.Write($request, 0, $request.Length)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $header = [Text.StringBuilder]::new()
        while ($header.Length -lt 8192 -and $watch.ElapsedMilliseconds -lt $TimeoutMs) {
            $stream.ReadTimeout = [Math]::Max(1, $TimeoutMs - [int]$watch.ElapsedMilliseconds)
            $next = $stream.ReadByte()
            if ($next -lt 0) { return $false }
            [void]$header.Append([char]$next)
            if ($header.ToString().EndsWith("`r`n`r`n")) {
                return ($header.ToString() -match '^HTTP/1\.[01] 200(?: |\r)')
            }
        }
        return $false
    } catch { return $false }
    finally { $client.Dispose() }
}

function Get-ProxyCandidates {
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($key in @('HTTPS_PROXY', 'HTTP_PROXY')) {
        foreach ($scope in @('Process','User')) {
            $value = [Environment]::GetEnvironmentVariable($key, $scope)
            if ($value) { try { $candidates.Add((Get-LocalProxy $value)) } catch {} }
        }
    }
    try {
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        if ($settings.ProxyEnable -eq 1 -and $settings.ProxyServer) {
            foreach ($entry in ($settings.ProxyServer -split ';')) {
                if ($entry -match '^(?:https?=)?([^=]+)$') {
                    try { $candidates.Add((Get-LocalProxy $matches[1])) } catch {}
                }
            }
        }
    } catch {}
    foreach ($port in @(7897,7890,10809,8080)) { $candidates.Add(('http://127.0.0.1:' + $port)) }
    return @($candidates | Select-Object -Unique)
}

function New-EnvPlan([string]$Directory, [string]$Proxy) {
    $proxy = Get-LocalProxy $Proxy
    $state = Read-EnvState $Directory
    $newline = "`r`n"
    if ($state.Text.Contains("`n") -and -not $state.Text.Contains("`r`n")) { $newline = "`n" }
    $lines = [regex]::Split($state.Text, '\r\n|\n|\r')
    $kept = [Collections.Generic.List[string]]::new()
    $bypass = [Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line -match '^\s*(?:export\s+)?(HTTP_PROXY|HTTPS_PROXY|NO_PROXY)\s*=\s*(.*)$') {
            $key = $matches[1]
            $raw = $matches[2].Trim()
            # Refuse multiline, expansions and ambiguous proxy assignments instead of guessing.
            $parsed = ''
            if ($raw -match '^"([^"\r\n]*)"\s*(?:#.*)?$') { $parsed = $matches[1] }
            elseif ($raw -match "^'([^'\r\n]*)'\s*(?:#.*)?$") { $parsed = $matches[1] }
            elseif ($raw -match '^[^\s"''`$#\\]*(?:\s+#.*)?$') { $parsed = ($raw -split '\s+#',2)[0] }
            else { throw '已有代理变量包含复杂语法，已停止。请先手动检查 .env。' }
            if ($parsed -match '[`$\\]') { throw '已有代理变量包含转义或变量引用，已停止自动修改。' }
            if ($key -ieq 'NO_PROXY') {
                if ($parsed.Contains('"')) { throw 'NO_PROXY 包含不能安全重写的引号，已停止。' }
                foreach ($part in ($parsed -split ',')) {
                    if ($part.Trim()) { $bypass.Add($part.Trim()) }
                }
            }
        } else {
            # Multiline non-proxy values can hide a proxy-looking line; reject conservatively.
            if ($line -match '^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*(["''])' ) {
                $quote = $matches[1]
                $rhs = ($line -split '=',2)[1].TrimStart()
                if ($rhs.Substring(1).IndexOf($quote) -lt 0) { throw '.env 含跨行引号值，已停止自动编辑。' }
            }
            $kept.Add($line)
        }
    }
    foreach ($local in @('localhost','127.0.0.1','::1')) { $bypass.Add($local) }
    $noProxy = (@($bypass | Select-Object -Unique) -join ',')
    while ($kept.Count -gt 0 -and $kept[$kept.Count-1] -eq '') { $kept.RemoveAt($kept.Count-1) }
    $kept.Add('HTTP_PROXY="' + $proxy + '"')
    $kept.Add('HTTPS_PROXY="' + $proxy + '"')
    $kept.Add('NO_PROXY="' + $noProxy + '"')
    $text = ($kept -join $newline) + $newline
    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    if ($state.Bom) { $bytes = [byte[]](@(239,187,191) + $bytes) }
    $conflicts = $state.Text -match '(?im)^\s*(?:export\s+)?(?:ALL_PROXY|WS_PROXY|WSS_PROXY)\s*='
    return [pscustomobject]@{ Directory=$Directory; Proxy=$proxy; NoProxy=$noProxy; Previous=$state;
        Bytes=$bytes; Hash=(Get-ByteHash $bytes); OtherProxyKeys=$conflicts }
}

function Save-EnvPlan($Plan) {
    $current = Read-EnvState $Plan.Directory
    if ($current.Exists -ne $Plan.Previous.Exists -or $current.Hash -ne $Plan.Previous.Hash) { throw '预览后 .env 已变化，请重新配置。' }
    if ($current.Exists -and $current.Hash -eq $Plan.Hash) { return '当前配置已经相同，无需修改，也未新增备份。' }
    $target = Join-Path $Plan.Directory '.env'
    $backupDir = Join-Path $Plan.Directory 'proxy-helper-backups'
    if (-not (Test-Path -LiteralPath $backupDir)) { [void][IO.Directory]::CreateDirectory($backupDir) }
    Assert-SafeDirectory $backupDir
    $id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N')
    $backup = Join-Path $backupDir ($id + '.env.bak')
    if ($current.Exists) { [IO.File]::WriteAllBytes($backup, $current.Bytes) }
    $record = [ordered]@{ version=1; id=$id; target=$target; existed=$current.Exists; beforeHash=$current.Hash;
        afterHash=$Plan.Hash; restored=$false; createdUtc=[DateTime]::UtcNow.ToString('o') }
    $manifest = Join-Path $backupDir ($id + '.json')
    [IO.File]::WriteAllText($manifest, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $temp = Join-Path $Plan.Directory ('.env.proxy-helper-' + $id + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $Plan.Bytes)
        $again = Read-EnvState $Plan.Directory
        if ($again.Exists -ne $current.Exists -or $again.Hash -ne $current.Hash) { throw '.env 在写入前发生变化，已停止。' }
        if ($current.Exists) { [IO.File]::Replace($temp, $target, [NullString]::Value) }
        else { [IO.File]::Move($temp, $target) }
        if ((Read-EnvState $Plan.Directory).Hash -ne $Plan.Hash) { throw '写入后的校验失败。请检查备份。' }
    } finally { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
    return "配置已写入并校验。`r`n恢复记录：$manifest`r`n`r`n请完全退出 ChatGPT/Codex，再重新打开并测试新会话的第一条消息。`r`n配置成功不代表所有重连原因都已解决。"
}

function Get-RestoreRecord([string]$Directory) {
    Assert-SafeDirectory $Directory
    $backupDir = Join-Path $Directory 'proxy-helper-backups'
    if (-not (Test-Path -LiteralPath $backupDir)) { throw '没有本工具的备份记录。' }
    Assert-SafeDirectory $backupDir
    $files = @(Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -File | Sort-Object Name -Descending)
    foreach ($file in $files) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '恢复记录不是普通文件。' }
        $record = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        if ($record.version -ne 1 -or $record.id -cne $file.BaseName -or
            $record.id -notmatch '^\d{8}T\d{9}Z-[a-f0-9]{32}$' -or
            $record.target -ine (Join-Path $Directory '.env')) { throw '恢复记录无效，已停止。' }
        if ($record.restored) { continue }
        return [pscustomobject]@{ Record=$record; Manifest=$file.FullName; Backup=(Join-Path $backupDir ($record.id + '.env.bak')) }
    }
    throw '没有尚未恢复的备份记录。'
}

function Restore-EnvConfig([string]$Directory) {
    $item = Get-RestoreRecord $Directory
    $record = $item.Record
    $state = Read-EnvState $Directory
    if (-not $state.Exists -or $state.Hash -ne $record.afterHash) {
        throw '当前 .env 与本工具上次写入的内容不同。为保护后续修改，已停止恢复。请手动查看备份。'
    }
    $target = Join-Path $Directory '.env'
    if ($record.existed) {
        $backupFile = Get-Item -LiteralPath $item.Backup -Force
        if ($backupFile.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '备份不是普通文件。' }
        $bytes = [IO.File]::ReadAllBytes($item.Backup)
        if ((Get-ByteHash $bytes) -ne $record.beforeHash) { throw '备份校验失败，未恢复。' }
        $temp = Join-Path $Directory ('.env.proxy-helper-restore-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllBytes($temp, $bytes)
            if ((Read-EnvState $Directory).Hash -ne $record.afterHash) { throw '恢复前 .env 已变化，已停止。' }
            [IO.File]::Replace($temp, $target, [NullString]::Value)
        } finally { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
        if ((Read-EnvState $Directory).Hash -ne $record.beforeHash) { throw '恢复后的校验失败。' }
    } else {
        if ((Read-EnvState $Directory).Hash -ne $record.afterHash) { throw '恢复前 .env 已变化，已停止。' }
        [IO.File]::Delete($target)
    }
    $record.restored = $true
    [IO.File]::WriteAllText($item.Manifest, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    return '已恢复到本次配置前的状态。请完全退出并重新打开客户端。'
}

function Show-ProxyHelper([string]$PreviewPath) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = [Windows.Forms.Form]::new()
    $form.Text = '本地代理配置助手 · v0.1.0'
    $form.ClientSize = [Drawing.Size]::new(680,510)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = [Drawing.Font]::new('Microsoft YaHei UI',10)
    $intro = [Windows.Forms.Label]::new()
    $intro.SetBounds(22,18,635,65)
    $intro.Text = "给 .codex/.env 明确指定本机代理，帮助排查反复重连。`r`n请先开启 Clash 等代理软件。工具不安装代理，也不保证解决所有重连。"
    $form.Controls.Add($intro)
    $dirLabel = [Windows.Forms.Label]::new(); $dirLabel.SetBounds(22,90,620,24)
    $dirLabel.Text = '配置目录（自动读取 CODEX_HOME，也可手动修改）'
    $form.Controls.Add($dirLabel)
    $directory = [Windows.Forms.TextBox]::new(); $directory.SetBounds(22,118,635,29)
    $directory.Text = Get-ConfigDirectory
    $form.Controls.Add($directory)
    $proxyLabel = [Windows.Forms.Label]::new(); $proxyLabel.SetBounds(22,162,620,24)
    $proxyLabel.Text = '本机 HTTP/Mixed 代理地址（支持直接输入端口号）'
    $form.Controls.Add($proxyLabel)
    $proxyBox = [Windows.Forms.ComboBox]::new(); $proxyBox.SetBounds(22,190,440,30)
    $form.Controls.Add($proxyBox)
    $detect = [Windows.Forms.Button]::new(); $detect.SetBounds(477,188,180,34); $detect.Text = '自动检测代理'
    $form.Controls.Add($detect)
    $apply = [Windows.Forms.Button]::new(); $apply.SetBounds(22,237,200,42); $apply.Text = '检查并配置'
    $form.Controls.Add($apply)
    $restore = [Windows.Forms.Button]::new(); $restore.SetBounds(235,237,200,42); $restore.Text = '恢复上一次配置'
    $form.Controls.Add($restore)
    $status = [Windows.Forms.TextBox]::new(); $status.SetBounds(22,294,635,195)
    $status.Multiline = $true; $status.ReadOnly = $true; $status.ScrollBars = 'Vertical'
    $status.Text = "使用顺序：自动检测代理 → 检查并配置 → 确认 → 重启客户端。`r`n`r`n检测仅向 chatgpt.com:443 请求代理隧道，不发送账号、密钥或对话。`r`n已有 .env 会先备份；恢复时发现后续修改将停止。"
    $form.Controls.Add($status)
    $detect.Add_Click({
        $detect.Enabled=$false; $apply.Enabled=$false; $restore.Enabled=$false
        try {
            $status.Text='正在检查本机代理，通常需要数秒，请稍候……'; $status.Refresh()
            $proxyBox.Items.Clear()
            foreach ($candidate in @(Get-ProxyCandidates)) {
                if (Test-ProxyTunnel $candidate 1500) { [void]$proxyBox.Items.Add($candidate) }
            }
            if ($proxyBox.Items.Count -gt 0) {
                $proxyBox.SelectedIndex=0
                $status.Text="找到 $($proxyBox.Items.Count) 个支持 CONNECT 的本机代理，请选择后点击「检查并配置」。`r`n此检测不验证登录、TLS 或模型请求是否正常。"
            } else { $status.Text='未找到可用代理。请开启代理软件，查看 HTTP/Mixed 端口并在上方输入，再点击「检查并配置」。' }
        } catch { $status.Text=$_.Exception.Message }
        finally { $detect.Enabled=$true; $apply.Enabled=$true; $restore.Enabled=$true }
    })
    $apply.Add_Click({
        $detect.Enabled=$false; $apply.Enabled=$false; $restore.Enabled=$false
        try {
            $proxy = Get-LocalProxy $proxyBox.Text
            $status.Text='正在验证代理并准备配置预览……'; $status.Refresh()
            if (-not (Test-ProxyTunnel $proxy)) { throw '代理隧道检测未通过，没有修改文件。请检查软件、端口和网络。' }
            $plan = New-EnvPlan $directory.Text.Trim() $proxy
            $message="将修改：$(Join-Path $plan.Directory '.env')`r`n`r`nHTTP_PROXY=$($plan.Proxy)`r`nHTTPS_PROXY=$($plan.Proxy)`r`nNO_PROXY=$($plan.NoProxy)`r`n`r`n保留其他设置；原文件（如有）会先备份。`r`n备份可能包含敏感设置，请勿上传到网上。"
            if ($plan.OtherProxyKeys) { $message += "`r`n`r`n注意：文件还有 ALL_PROXY/WS_PROXY/WSS_PROXY，工具会保留；它们可能影响最终代理选择。" }
            $answer = [Windows.Forms.MessageBox]::Show($form,$message,'确认配置',[Windows.Forms.MessageBoxButtons]::OKCancel,[Windows.Forms.MessageBoxIcon]::Information)
            if ($answer -eq [Windows.Forms.DialogResult]::OK) { $status.Text = Save-EnvPlan $plan }
            else { $status.Text='已取消，没有修改配置。' }
        } catch { $status.Text="未完成：$($_.Exception.Message)`r`n如果提示拒绝访问，请检查当前用户的目录权限；无需默认以管理员身份运行。" }
        finally { $detect.Enabled=$true; $apply.Enabled=$true; $restore.Enabled=$true }
    })
    $restore.Add_Click({
        try {
            $item = Get-RestoreRecord $directory.Text.Trim()
            $answer = [Windows.Forms.MessageBox]::Show($form,"将恢复配置目录：$($directory.Text.Trim())`r`n记录时间（UTC）：$($item.Record.createdUtc)`r`n恢复前会校验当前文件，若已有后续修改则停止。",'确认恢复',[Windows.Forms.MessageBoxButtons]::OKCancel,[Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -eq [Windows.Forms.DialogResult]::OK) { $status.Text = Restore-EnvConfig $directory.Text.Trim() }
        } catch { $status.Text=$_.Exception.Message }
    })
    if ($PreviewPath) {
        # Render our own form offscreen for layout checks, without operating other apps.
        $directory.Text = 'C:\Users\YourName\.codex'
        $directory.SelectionStart = $directory.Text.Length
        $form.ShowInTaskbar = $false
        $form.Opacity = 0
        $form.Show()
        [Windows.Forms.Application]::DoEvents()
        $bitmap = [Drawing.Bitmap]::new($form.Width, $form.Height)
        try { $form.DrawToBitmap($bitmap, [Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)); $bitmap.Save($PreviewPath) }
        finally { $bitmap.Dispose() }
    } else {
        $form.Add_Shown({ $detect.PerformClick() })
        [void]$form.ShowDialog()
    }
    $form.Dispose()
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Show-ProxyHelper }
    catch { Write-Error $_; exit 1 }
}
