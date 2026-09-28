# Локальные регрессионные тесты: системный hosts и Планировщик не изменяются.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'AutoFix.Common.ps1')
$script:Passed = 0
function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "FAIL: $Name" }
    $script:Passed++
    Write-Host "PASS: $Name"
}
function Assert-Throws([scriptblock]$Operation, [string]$Name) {
    $thrown = $false
    try { & $Operation | Out-Null } catch { $thrown = $true }
    Assert-Equal $thrown $true $Name
}
$repositoryRoot = Split-Path $PSScriptRoot -Parent
foreach ($scriptName in @('AutoFix.Common.ps1', 'Manage-AutoFixTask.ps1', 'Roblox-CDN-AutoFix.ps1', 'Roblox-CDN-Monitor.ps1')) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot $scriptName), [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-Equal $parseErrors.Count 0 "PowerShell syntax: $scriptName"
}
$foreign = "127.0.0.1 localhost`r`n1.2.3.4 example.com # preserve`r`n"
foreach ($invalid in @('', '127.1', '127.0.0.1', '10.0.0.1', '169.254.1.2', '172.16.1.1', '192.168.1.1', '100.64.0.1', '224.0.0.1', '1.2.3.999', '01.2.3.4', '::1', '1.2.3.4;whoami')) {
    Assert-Equal (Test-IPv4 $invalid) $false "reject invalid/private IP: $invalid"
}
Assert-Equal (Test-IPv4 '3.171.117.54') $true 'valid CDN IPv4'
Assert-Equal (New-RobloxProcessStartQuery @('RobloxPlayerBeta', 'AltPlayer.exe')) "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'RobloxPlayerBeta.exe' OR ProcessName = 'AltPlayer.exe'" 'configured process names build a WMI filter'
Assert-Throws { New-RobloxProcessStartQuery @('RobloxPlayerBeta'' OR ProcessName = ''evil') } 'WMI filter rejects query injection'
$managed = "# RobloxCDNAutoFix BEGIN`r`n3.4.5.6 tr.rbxcdn.com`r`n# RobloxCDNAutoFix END`r`n"
Assert-Equal (Get-UnmanagedHostsText '') '' 'empty hosts'
Assert-Equal (Get-UnmanagedHostsText $foreign) $foreign 'foreign lines unchanged'
Assert-Equal (Get-UnmanagedHostsText ($foreign + $managed)) $foreign 'remove own block only'
Assert-Equal (Get-UnmanagedHostsText ($managed + $foreign)) $foreign 'block before foreign lines'
Assert-Equal (Get-UnmanagedHostsText "x`ny`rz") "x`ny`rz" 'preserve mixed line endings'
Assert-Equal (Get-UnmanagedHostsText ([string][char]0xfeff + $foreign + $managed)) ([string][char]0xfeff + $foreign) 'preserve UTF8 BOM'
Assert-Equal (Test-ForeignMapping "1.2.3.4 other tr.rbxcdn.com # alias") $true 'foreign alias detected'
Assert-Equal (Test-ForeignMapping "::1 TR.RBXCDN.COM") $true 'foreign IPv6 detected'
Assert-Equal (Test-ForeignMapping "x`r1.2.3.4 tr.rbxcdn.com") $true 'CR-only hosts'
Assert-Equal (Test-ForeignMapping "# 1.2.3.4 tr.rbxcdn.com") $false 'comment is not mapping'
Assert-Equal (Test-ForeignMapping "1.2.3.4 not-tr.rbxcdn.com") $false 'exact domain only'
Assert-Throws { Get-UnmanagedHostsText ($managed + $managed) } 'duplicate block refused'
Assert-Throws { Get-UnmanagedHostsText "# RobloxCDNAutoFix BEGIN`n1.2.3.4 tr.rbxcdn.com" } 'incomplete block refused'
Assert-Throws { Get-UnmanagedHostsText "# RobloxCDNAutoFix END" } 'orphan end refused'
Assert-Throws { Get-UnmanagedHostsText ($managed.Replace('tr.rbxcdn.com', 'other.example')) } 'foreign block content protected'
Assert-Throws { Get-UnmanagedHostsText ($managed.Replace('tr.rbxcdn.com', 'tr.rbxcdn.com other.example')) } 'foreign alias inside block protected'
$legacy = "# RobloxCDNAutoFix - запись добавлена скриптом - 2026-01-01 01:02:03`r`n1.2.3.4 tr.rbxcdn.com`r`n"
Assert-Equal (Get-UnmanagedHostsText ($foreign + $legacy)) $foreign 'legacy own marker migration'
Assert-Equal (Get-UnmanagedHostsText "1.2.3.4 tr.rbxcdn.com`n") "1.2.3.4 tr.rbxcdn.com`n" 'unmarked CDN line preserved'
Assert-Throws { Remove-ProtectedTree $PSScriptRoot } 'repository deletion refused'

$fixture = Join-Path $PSScriptRoot ('.fixtures_' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
try {
    $script:HostsPath = Join-Path $fixture 'hosts'
    $script:DataRoot = $fixture
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'backups')) | Out-Null
    function Assert-ProtectedPath {
        param([string]$Path, [switch]$AllowChildCreation)
        if ($Path -ne $fixture -and -not $Path.StartsWith($fixture + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Test attempted to access a real system path.'
        }
        Assert-NoReparsePoint $Path
    }
    [IO.File]::WriteAllText($script:HostsPath, $foreign, (New-Object Text.UTF8Encoding($true)))
    $before = Read-HostsSnapshot
    $transaction = Write-HostsTransaction $before ($before.Text + $managed)
    Assert-Equal ((Get-FileHash $transaction.Backup).Hash) $before.Hash 'backup precedes write and matches original'
    Assert-Equal ((Get-FileHash $script:HostsPath).Hash) $transaction.AfterHash 'atomic write succeeded'
    Assert-Throws { Set-HostsBytes $before.Bytes $before.Hash } 'concurrent modification refused'
    Set-HostsBytes $transaction.Before $transaction.AfterHash
    Assert-Equal ((Get-FileHash $script:HostsPath).Hash) $before.Hash 'byte-exact rollback'
    $second = Write-HostsTransaction (Read-HostsSnapshot) ($before.Text + $managed)
    Assert-Equal ($second.Backup -ne $transaction.Backup) $true 'backup never overwritten'
    Assert-Equal ((Get-FileHash $transaction.Backup).Hash) $before.Hash 'first backup preserved'
    [IO.File]::WriteAllText((Join-Path $fixture 'RobloxCDNMonitor.log'), ('x' * 1MB))
    Write-RotatingLog 'RobloxCDNMonitor.log' 'rotation test'
    Assert-Equal (Test-Path (Join-Path $fixture 'RobloxCDNMonitor.log.1')) $true 'log rotation'
    Assert-Equal ((Get-Item (Join-Path $fixture 'RobloxCDNMonitor.log')).Length -lt 1KB) $true 'new log bounded'
    Assert-Throws { Write-RotatingLog '..\outside.log' 'test' } 'log path traversal refused'
    $lock = Enter-AutoFixLock
    try { Assert-Throws { Enter-AutoFixLock } 'exclusive operation lock' }
    finally { $lock.Dispose() }
    $script:InstallRoot = Join-Path $fixture 'installation'
    $release = Join-Path $script:InstallRoot 'versions\test'
    [IO.Directory]::CreateDirectory($release) | Out-Null
    $manifest = @{}
    foreach ($name in $script:RuntimeFiles) {
        $path = Join-Path $release $name
        [IO.File]::WriteAllText($path, '# fixture only')
        $manifest[$name] = (Get-FileHash $path).Hash
    }
    [IO.File]::WriteAllText((Join-Path $release 'manifest.json'), ($manifest | ConvertTo-Json))
    Assert-Release $release
    Assert-Equal $true $true 'valid release hashes'
    [IO.File]::AppendAllText((Join-Path $release $script:RuntimeFiles[0]), ' changed')
    Assert-Throws { Assert-Release $release } 'tampered runtime rejected'
    Remove-ProtectedTree $script:InstallRoot
    Assert-Equal (Test-Path $script:InstallRoot) $false 'scoped installation removal'
    [IO.File]::WriteAllBytes($script:HostsPath, [byte[]]@())
    $empty = Read-HostsSnapshot
    $emptyTransaction = Write-HostsTransaction $empty $managed
    Set-HostsBytes $emptyTransaction.Before $emptyTransaction.AfterHash
    Assert-Equal ((Get-Item $script:HostsPath).Length) 0 'empty hosts rollback'
    $originalWriter = (Get-Command Set-HostsBytes).ScriptBlock
    $script:FailAfterWrite = $true
    function Set-HostsBytes {
        param([byte[]]$Bytes, [string]$ExpectedHash)
        & $originalWriter -Bytes $Bytes -ExpectedHash $ExpectedHash
        if ($script:FailAfterWrite) {
            $script:FailAfterWrite = $false
            throw 'Simulated error after atomic replacement.'
        }
    }
    Assert-Throws { Write-HostsTransaction (Read-HostsSnapshot) $managed } 'write error reported'
    Assert-Equal ((Get-Item $script:HostsPath).Length) 0 'rollback on write error after replacement'
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ne $PSScriptRoot -or [IO.Path]::GetFileName($resolved) -notmatch '^\.fixtures_[a-f0-9]{32}$') {
        throw 'Unsafe fixture cleanup path.'
    }
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $fixture 'backups') -File)) { [IO.File]::Delete($file.FullName) }
    [IO.Directory]::Delete((Join-Path $fixture 'backups'))
    foreach ($file in @(Get-ChildItem -LiteralPath $fixture -File)) { [IO.File]::Delete($file.FullName) }
    [IO.Directory]::Delete($fixture)
}
Write-Host ("Passed: {0}" -f $script:Passed)
