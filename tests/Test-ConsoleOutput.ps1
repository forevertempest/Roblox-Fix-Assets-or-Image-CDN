param([switch]$Install)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$executable = Join-Path $root 'release\windows-x64.exe'
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $executable
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardOutputEncoding = [Text.Encoding]::UTF8
$start.StandardErrorEncoding = [Text.Encoding]::UTF8
$process = New-Object Diagnostics.Process
$process.StartInfo = $start

try {
    [void]$process.Start()
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $menuInput = if ($Install) { "2`n1`n`n5`n`n0`n" } else { "5`n`n2`n0`n`n0`n" }
    $process.StandardInput.Write($menuInput)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(120000)) {
        $process.Kill()
        throw 'Console status timed out.'
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Menu exited with code $($process.ExitCode)." }
    $output = $outputTask.GetAwaiter().GetResult()
    $statePrefix = 'Состояние автопроверки:'
    $absent = 'Автоматическая проверка не установлена.'
    if (-not $output.Contains($statePrefix) -and -not $output.Contains($absent)) {
        throw ('Status result did not reach the main window: ' + $output)
    }
    if ($output.Contains([char]0xFFFD)) { throw 'Invalid UTF-8 in console output.' }
    if ($Install -and -not $output.Contains('Автопроверка установлена.')) {
        throw ('Installation result did not reach the main window: ' + $output)
    }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $output.Contains('Ожидание подтверждения прав администратора')) {
        throw 'The test did not exercise the elevated output relay.'
    }
    if (([regex]::Matches($output, 'ROBLOX CDN AUTOFIX')).Count -lt 3) {
        throw 'The menu did not remain available after status and cancellation.'
    }
    if ($errorTask.GetAwaiter().GetResult().Trim()) { throw 'Unexpected stderr output.' }
    Write-Host 'PASS: status output reaches the main console, UTF-8 is intact, menu stays open.'
}
finally {
    $process.Dispose()
}
