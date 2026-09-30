# Проверяет WMI-событие и SYSTEM-диагностику, не разрешая ремонт hosts.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'AutoFix.Common.ps1')
$app = Join-Path $root 'release\windows-x64.exe'
$fixture = Join-Path $PSScriptRoot ('.fixtures_' + [Guid]::NewGuid().ToString('N'))
$trigger = Join-Path $fixture 'AutoFixV2TestPlayer.exe'
$before = (Get-FileHash -LiteralPath $script:HostsPath).Hash
try {
    & $app monitor install --auto-repair false --process-names AutoFixV2TestPlayer
    if ($LASTEXITCODE -ne 0) { throw 'Test watcher installation failed.' }
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    [IO.File]::Copy((Join-Path ([Environment]::SystemDirectory) 'where.exe'), $trigger)
    $log = Join-Path $script:DataRoot 'RobloxCDNMonitor.log'
    $oldLength = if (Test-Path -LiteralPath $log) { (Get-Item -LiteralPath $log).Length } else { 0 }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $trigger
    $start.Arguments = '/?'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $process = [Diagnostics.Process]::Start($start)
    $null = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    $process.Dispose()
    $passed = $false
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        Start-Sleep -Seconds 1
        $bytes = [IO.File]::ReadAllBytes($log)
        $offset = if ($bytes.Length -ge $oldLength) { $oldLength } else { 0 }
        $text = [Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
        if ($text.Contains('[DIAGNOSE] Fix required:')) { $passed = $true; break }
    }
    if (-not $passed) { throw 'No SYSTEM diagnosis after WMI event. Inspect RobloxCDNMonitor.log.' }
    if ((Get-FileHash -LiteralPath $script:HostsPath).Hash -ne $before) { throw 'System hosts unexpectedly changed.' }
    Write-Host 'PASS: WMI event launches protected SYSTEM native diagnosis; hosts unchanged.'
}
finally {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fixture)) -ne $PSScriptRoot -or [IO.Path]::GetFileName($fixture) -notmatch '^\.fixtures_[a-f0-9]{32}$') { throw 'Unsafe test cleanup path.' }
    if ([IO.File]::Exists($trigger)) { [IO.File]::Delete($trigger) }
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture) }
    & $app monitor install
    if ($LASTEXITCODE -ne 0) { throw 'Could not restore normal monitoring.' }
}
