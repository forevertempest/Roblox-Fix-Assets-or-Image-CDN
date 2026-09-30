$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$executable = Join-Path $root 'release\windows-x64.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Build the Windows release first.' }

$settingsDirectory = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Tempest\RobloxCDNAutoFixV2'
$settingsPath = Join-Path $settingsDirectory 'settings.json'
$hadSettings = Test-Path -LiteralPath $settingsPath -PathType Leaf
$originalBytes = if ($hadSettings) { [IO.File]::ReadAllBytes($settingsPath) } else { $null }
$original = if ($hadSettings) { [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json } else { [pscustomobject]@{ AutoRepair = $true; Theme = 'neon' } }
$expectedTheme = switch ($original.Theme) { 'neon' { 'amber' } 'amber' { 'mono' } default { 'neon' } }
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('RobloxCDNAutoFix-settings-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
$inputPath = Join-Path $temporaryRoot 'input.txt'
$outputPath = Join-Path $temporaryRoot 'output.txt'
$errorPath = Join-Path $temporaryRoot 'error.txt'
[IO.File]::WriteAllText($inputPath, "1`n2`n33`n3`nTestPlayer.exe,AltGame`n4`n0`n`n", [Text.Encoding]::ASCII)

try {
    $process = Start-Process -FilePath $executable -ArgumentList 'settings' -WindowStyle Hidden `
        -RedirectStandardInput $inputPath -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath `
        -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Settings menu exited with code $($process.ExitCode)." }

    $saved = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
    if ($saved.AutoRepair -eq [bool]$original.AutoRepair) { throw 'AutoRepair setting did not toggle.' }
    if ($saved.CooldownMinutes -ne 33) { throw 'Cooldown setting did not save.' }
    if ($saved.ProcessNames -join ',' -cne 'TestPlayer,AltGame') { throw 'Process names were not normalized and saved.' }
    if ($saved.Theme -cne $expectedTheme) { throw 'Theme setting did not save.' }
    if ($saved.PSObject.Properties.Name -contains 'PollSeconds') { throw 'Obsolete setting was saved.' }

    Write-Host 'PASS: AutoRepair, cooldown, process names, and theme persist.'
}
finally {
    if ($hadSettings) {
        [IO.File]::WriteAllBytes($settingsPath, $originalBytes)
    }
    elseif (Test-Path -LiteralPath $settingsPath) {
        [IO.File]::Delete($settingsPath)
        if ((Test-Path -LiteralPath $settingsDirectory) -and -not (Get-ChildItem -LiteralPath $settingsDirectory -Force | Select-Object -First 1)) {
            [IO.Directory]::Delete($settingsDirectory)
        }
    }
    foreach ($file in @($inputPath, $outputPath, $errorPath)) {
        if (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) }
    }
    [IO.Directory]::Delete($temporaryRoot)
}
