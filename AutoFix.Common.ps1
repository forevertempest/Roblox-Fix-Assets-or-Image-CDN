# Общие операции с защищёнными файлами, журналами и блоком hosts.
$script:SystemDir = [Environment]::SystemDirectory
$script:PowerShellExe = Join-Path $script:SystemDir 'WindowsPowerShell\v1.0\powershell.exe'
$script:CurlExe = Join-Path $script:SystemDir 'curl.exe'
$script:IpconfigExe = Join-Path $script:SystemDir 'ipconfig.exe'
$script:InstallRoot = Join-Path ([Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion', 'ProgramFilesDir', $null)) 'RobloxCDNAutoFix'
$script:DataRoot = Join-Path ([Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders', 'Common AppData', $null)) 'RobloxCDNAutoFix-Secure'
$script:HostsPath = Join-Path $script:SystemDir 'drivers\etc\hosts'
$script:RuntimeFiles = @('Roblox-CDN-Monitor.ps1', 'Roblox-CDN-AutoFix.ps1', 'AutoFix.Common.ps1')
$script:TaskName = 'Roblox CDN AutoFix'
$script:MonitorSettingsPath = Join-Path $script:DataRoot 'monitor-settings.json'
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    throw 'Запусти 64-разрядный Windows PowerShell через CMD-файл проекта.'
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IPv4 {
    param([string]$Value)
    if ($Value -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') { return $false }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or $parsed.ToString() -cne $Value) { return $false }
    $octets = $parsed.GetAddressBytes()
    if ($octets[0] -in @(0, 10, 127) -or $octets[0] -ge 224 -or
        ($octets[0] -eq 169 -and $octets[1] -eq 254) -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168) -or
        ($octets[0] -eq 100 -and $octets[1] -ge 64 -and $octets[1] -le 127)) { return $false }
    return $true
}

function Assert-NoReparsePoint {
    param([string]$Path)
    $currentPath = [IO.Path]::GetFullPath($Path)
    while ($currentPath) {
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Обнаружена ссылка или junction: $currentPath"
            }
        }
        $currentPath = [IO.Path]::GetDirectoryName($currentPath)
    }
}

function Assert-ProtectedPath {
    param([string]$Path, [switch]$AllowChildCreation)
    Assert-NoReparsePoint $Path
    $acl = Get-Acl -LiteralPath $Path
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) {
        throw "Недоверенный владелец: $Path"
    }
    $writeMask = [Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    if ($AllowChildCreation) {
        $writeMask = [Security.AccessControl.FileSystemRights]'Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -eq 0) { throw "Отсутствует проверяемый ACL: $Path" }
    foreach ($rule in $rules) {
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($rule.AccessControlType -eq 'Allow' -and
            (($rule.FileSystemRights -band $writeMask) -ne 0 -or ([int]$rule.FileSystemRights -band 1342177280) -ne 0) -and
            $rule.IdentityReference.Value -notin $trusted) {
            throw "Небезопасные права записи: $Path"
        }
    }
}

function New-ProtectedDirectory {
    param([string]$Path)
    Assert-NoReparsePoint $Path
    $parentPath = [IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        throw "Нет родительской папки: $parentPath"
    }
    $ancestor = $parentPath
    while ($ancestor) {
        Assert-ProtectedPath $ancestor -AllowChildCreation
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    if (Test-Path -LiteralPath $Path) {
        Assert-ProtectedPath $Path
        return
    }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)')
    [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
    Assert-ProtectedPath $Path
}

function Initialize-AutoFixData {
    New-ProtectedDirectory $script:DataRoot
    New-ProtectedDirectory (Join-Path $script:DataRoot 'backups')
}

function Write-MonitorSettings {
    param(
        [ValidateRange(1, 1440)][int]$CooldownMinutes = 30,
        [bool]$AutoRepair = $true,
        [string]$ProcessNames = 'RobloxPlayerBeta'
    )
    if ($ProcessNames -notmatch '^[A-Za-z0-9_.-]{1,80}(,[A-Za-z0-9_.-]{1,80}){0,7}$') {
        throw 'Некорректный список процессов.'
    }
    $settings = [ordered]@{
        CooldownMinutes = $CooldownMinutes
        AutoRepair = $AutoRepair
        ProcessNames = @($ProcessNames -split ',')
    }
    Assert-ProtectedPath $script:DataRoot
    $temporary = Join-Path $script:DataRoot ('monitor-settings.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($temporary, ($settings | ConvertTo-Json), $encoding)
        if (Test-Path -LiteralPath $script:MonitorSettingsPath) {
            Assert-ProtectedPath $script:MonitorSettingsPath
            [IO.File]::Replace($temporary, $script:MonitorSettingsPath, [NullString]::Value)
        }
        else { [IO.File]::Move($temporary, $script:MonitorSettingsPath) }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Read-MonitorSettings {
    $result = [pscustomobject]@{ CooldownMinutes = 30; AutoRepair = $true; ProcessNames = @('RobloxPlayerBeta') }
    if (-not (Test-Path -LiteralPath $script:MonitorSettingsPath)) { return $result }
    Assert-ProtectedPath $script:MonitorSettingsPath
    $parsed = [IO.File]::ReadAllText($script:MonitorSettingsPath) | ConvertFrom-Json
    if ($parsed.CooldownMinutes -as [int] -lt 1 -or $parsed.CooldownMinutes -as [int] -gt 1440) { throw 'Повреждены настройки мониторинга.' }
    $names = @($parsed.ProcessNames | ForEach-Object { [string]$_ })
    if ($names.Count -lt 1 -or $names.Count -gt 8 -or ($names -join ',') -notmatch '^[A-Za-z0-9_.-]{1,80}(,[A-Za-z0-9_.-]{1,80}){0,7}$') { throw 'Повреждены настройки мониторинга.' }
    $result.CooldownMinutes = [int]$parsed.CooldownMinutes
    $result.AutoRepair = [bool]$parsed.AutoRepair
    $result.ProcessNames = $names
    return $result
}

function Enter-AutoFixLock {
    param([ValidateSet('operation.lock', 'installation.lock')][string]$Name = 'operation.lock')
    Assert-ProtectedPath $script:DataRoot
    $path = Join-Path $script:DataRoot $Name
    Assert-NoReparsePoint $path
    if (Test-Path -LiteralPath $path) { Assert-ProtectedPath $path }
    try {
        return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch {
        throw 'Другая операция AutoFix уже выполняется. Повтори запуск после её завершения.'
    }
}

function Write-RotatingLog {
    param([string]$Name, [string]$Message)
    if ($Name -notin @('RobloxCDNAutoFix.log', 'RobloxCDNMonitor.log', 'Installer.log')) {
        throw 'Недопустимое имя журнала.'
    }
    $path = Join-Path $script:DataRoot $Name
    Assert-ProtectedPath $script:DataRoot
    foreach ($logFile in @($path, ($path + '.1'))) {
        Assert-NoReparsePoint $logFile
        if (Test-Path -LiteralPath $logFile) { Assert-ProtectedPath $logFile }
    }
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge 1MB) {
        if (Test-Path -LiteralPath ($path + '.1')) { [IO.File]::Delete($path + '.1') }
        [IO.File]::Move($path, $path + '.1')
    }
    $line = '[{0}] {1}{2}' -f [DateTime]::UtcNow.ToString('o'), $Message, [Environment]::NewLine
    [IO.File]::AppendAllText($path, $line, (New-Object Text.UTF8Encoding($false)))
}

function Get-BytesHash {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Assert-Release {
    param([string]$Directory)
    Assert-ProtectedPath $script:InstallRoot
    Assert-ProtectedPath (Join-Path $script:InstallRoot 'versions')
    $versionsPath = (Join-Path $script:InstallRoot 'versions') + '\'
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Directory)) -ne $versionsPath.TrimEnd('\')) {
        throw 'Исполняемый код находится вне защищённой установки.'
    }
    Assert-ProtectedPath $Directory
    $manifestPath = Join-Path $Directory 'manifest.json'
    Assert-ProtectedPath $manifestPath
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    foreach ($name in $script:RuntimeFiles) {
        $path = Join-Path $Directory $name
        Assert-ProtectedPath $path
        $expected = $manifest.PSObject.Properties[$name].Value
        if ($expected -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected) {
            throw "Нарушена целостность: $name"
        }
    }
}

function Read-HostsSnapshot {
    Assert-ProtectedPath ([IO.Path]::GetDirectoryName($script:HostsPath))
    Assert-NoReparsePoint $script:HostsPath
    Assert-ProtectedPath $script:HostsPath
    $bytes = [IO.File]::ReadAllBytes($script:HostsPath)
    if ($bytes.Length -gt 4MB) { throw 'hosts превышает допустимый размер 4 МБ.' }
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    try { $text = $encoding.GetString($bytes) }
    catch { $encoding = [Text.Encoding]::Default; $text = $encoding.GetString($bytes) }
    if ($text.IndexOf([char]0) -ge 0) { throw 'Неподдерживаемая кодировка hosts.' }
    return [pscustomobject]@{ Bytes = $bytes; Text = $text; Encoding = $encoding; Hash = (Get-BytesHash $bytes) }
}

function Get-UnmanagedHostsText {
    param([string]$Text)
    $lines = [regex]::Matches($Text, '[^\r\n]*(?:\r\n|\n|\r|$)')
    $result = New-Object Text.StringBuilder
    $inside = $false
    $legacy = $false
    $seen = $false
    foreach ($match in $lines) {
        $raw = $match.Value
        $line = $raw.TrimEnd([char[]]@([char]13, [char]10))
        if ($line -eq '# RobloxCDNAutoFix BEGIN') {
            if ($inside -or $seen -or $legacy) { throw 'Повреждён или продублирован блок AutoFix.' }
            $inside = $true; $seen = $true
            continue
        }
        if ($line -eq '# RobloxCDNAutoFix END') {
            if (-not $inside) { throw 'Нет начала блока AutoFix.' }
            $inside = $false
            continue
        }
        if ($inside -or $legacy) {
            if ($line -notmatch '^\s*\d{1,3}(?:\.\d{1,3}){3}\s+tr\.rbxcdn\.com\s*$') {
                throw 'В блоке AutoFix есть неизвестные строки. Автоматическое изменение остановлено.'
            }
            $legacy = $false
            continue
        }
        if ($line -match '^# RobloxCDNAutoFix - (?:запись добавлена скриптом|managed entry) - \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') {
            if ($seen) { throw 'Дублирующая метка AutoFix.' }
            $legacy = $true; $seen = $true
            continue
        }
        [void]$result.Append($raw)
    }
    if ($inside -or $legacy) { throw 'Незавершённый блок AutoFix.' }
    return $result.ToString()
}

function Test-ForeignMapping {
    param([string]$Text)
    foreach ($line in ($Text -split '\r\n|\n|\r')) {
        $content = ($line -split '#', 2)[0].Trim()
        $parts = @($content -split '\s+')
        if ($parts.Count -ge 2 -and $parts[1..($parts.Count - 1)] -icontains 'tr.rbxcdn.com') { return $true }
    }
    return $false
}

function Write-HostsTransaction {
    param($Snapshot, [string]$Text)
    $backupDirectory = Join-Path $script:DataRoot 'backups'
    Assert-ProtectedPath $backupDirectory
    $backup = Join-Path $backupDirectory ('hosts_{0}_{1}.bak' -f [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmssfff'), [Guid]::NewGuid().ToString('N'))
    $stream = [IO.File]::Open($backup, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Snapshot.Bytes, 0, $Snapshot.Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    if ((Get-FileHash -LiteralPath $backup).Hash -ne $Snapshot.Hash) { throw 'Проверка резервной копии не прошла.' }
    [IO.File]::WriteAllText($backup + '.sha256', $Snapshot.Hash)
    $newBytes = $Snapshot.Encoding.GetBytes($Text)
    $newHash = Get-BytesHash $newBytes
    try { Set-HostsBytes -Bytes $newBytes -ExpectedHash $Snapshot.Hash }
    catch {
        $failure = $_.Exception.Message
        try {
            Assert-ProtectedPath $script:HostsPath
            $currentHash = (Get-FileHash -LiteralPath $script:HostsPath).Hash
            if ($currentHash -eq $newHash) { Set-HostsBytes -Bytes $Snapshot.Bytes -ExpectedHash $newHash }
            elseif ($currentHash -ne $Snapshot.Hash) { throw 'Обнаружено постороннее изменение hosts.' }
        }
        catch { throw "Ошибка записи: $failure Откат не завершён: $($_.Exception.Message) Backup: $backup" }
        throw "Ошибка записи: $failure Исходный hosts сохранён. Backup: $backup"
    }
    return [pscustomobject]@{ Backup = $backup; Before = $Snapshot.Bytes; AfterHash = $newHash }
}

function Set-HostsBytes {
    param([byte[]]$Bytes, [string]$ExpectedHash)
    Assert-NoReparsePoint $script:HostsPath
    Assert-ProtectedPath $script:HostsPath
    Assert-ProtectedPath ([IO.Path]::GetDirectoryName($script:HostsPath))
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($script:HostsPath)) ('RobloxCDNAutoFix-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        Set-Acl -LiteralPath $temporary -AclObject (Get-Acl -LiteralPath $script:HostsPath)
        if ((Get-FileHash -LiteralPath $script:HostsPath).Hash -ne $ExpectedHash) {
            throw 'hosts изменён другой программой. Запись отменена.'
        }
        [IO.File]::Replace($temporary, $script:HostsPath, [NullString]::Value)
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Clear-AutoFixDns {
    & $script:IpconfigExe /flushdns | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось очистить DNS-кэш Windows.' }
}

function Remove-ProtectedTree {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($fullPath -ne $script:InstallRoot -and
        [IO.Path]::GetDirectoryName($fullPath) -ne (Join-Path $script:InstallRoot 'versions')) {
        throw 'Удаление за пределами установленной программы запрещено.'
    }
    if (-not (Test-Path -LiteralPath $fullPath)) { return }
    Assert-ProtectedPath $fullPath
    $children = @(Get-ChildItem -LiteralPath $fullPath -Force)
    foreach ($child in $children) {
        Assert-ProtectedPath $child.FullName
        if ($child.PSIsContainer) {
            Remove-VerifiedChildren $child.FullName
            [IO.Directory]::Delete($child.FullName)
        }
        else { [IO.File]::Delete($child.FullName) }
    }
    [IO.Directory]::Delete($fullPath)
}

function Remove-VerifiedChildren {
    param([string]$Directory)
    foreach ($child in @(Get-ChildItem -LiteralPath $Directory -Force)) {
        Assert-ProtectedPath $child.FullName
        if ($child.PSIsContainer) {
            Remove-VerifiedChildren $child.FullName
            [IO.Directory]::Delete($child.FullName)
        }
        else { [IO.File]::Delete($child.FullName) }
    }
}
