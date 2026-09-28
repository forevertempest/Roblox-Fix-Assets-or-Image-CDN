# Запускать без повышения прав после установки мониторинга.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'AutoFix.Common.ps1')
if (Test-IsAdministrator) { throw 'Запусти тест из обычного, не повышенного PowerShell.' }
if (-not (Test-Path -LiteralPath $script:InstallRoot)) { throw 'Сначала установи мониторинг.' }
$tested = 0
foreach ($release in @(Get-ChildItem -LiteralPath (Join-Path $script:InstallRoot 'versions') -Directory)) {
    Assert-Release $release.FullName
    foreach ($name in @($script:RuntimeFiles) + @('manifest.json')) {
        $path = Join-Path $release.FullName $name
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $denied = $false
        try {
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $stream.Dispose()
        }
        catch [UnauthorizedAccessException] { $denied = $true }
        if (-not $denied) { throw "FAIL: ordinary user can open for writing: $path" }
        if ((Get-FileHash -LiteralPath $path).Hash -ne $hash) { throw 'File changed during test.' }
        Write-Host "PASS: Access Denied: $name"
        $tested++
    }
}
foreach ($directory in @($script:InstallRoot, (Join-Path $script:InstallRoot 'versions'), $script:DataRoot) +
    @(Get-ChildItem -LiteralPath (Join-Path $script:InstallRoot 'versions') -Directory | Select-Object -ExpandProperty FullName)) {
    Assert-ProtectedPath $directory
    $probe = Join-Path $directory ('write-probe-' + [Guid]::NewGuid().ToString('N'))
    $denied = $false
    try {
        $stream = [IO.File]::Open($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
        [IO.File]::Delete($probe)
    }
    catch [UnauthorizedAccessException] { $denied = $true }
    if (-not $denied) { throw "FAIL: directory is writable: $directory" }
    Write-Host "PASS: directory creation denied: $directory"
}
if ($tested -eq 0) { throw 'No installed runtime files were tested.' }
$scheduler = New-Object -ComObject 'Schedule.Service'
$scheduler.Connect()
$task = $scheduler.GetFolder('\').GetTask($script:TaskName)
$descriptor = $task.GetSecurityDescriptor(7)
$denied = $false
try { $task.SetSecurityDescriptor($descriptor, 0x10) }
catch {
    if ($_.Exception.HResult -eq -2147024891 -or $_.Exception.InnerException.HResult -eq -2147024891) { $denied = $true }
    else { throw }
}
if (-not $denied) { throw 'FAIL: ordinary user can change task permissions.' }
Write-Host 'PASS: task permission change denied'
Write-Host "Passed: $tested file write denials; directory ACL checks passed."
