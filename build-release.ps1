[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$project = Join-Path $root 'console\RobloxCDNAutoFix.Console.csproj'
$release = Join-Path $root 'release'
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source
$nuget = 'https://api.nuget.org/v3/index.json'

function Invoke-Dotnet {
    param([string[]]$Arguments)
    & $dotnet @Arguments
    if ($LASTEXITCODE -ne 0) { throw "dotnet завершился с кодом $LASTEXITCODE." }
}

foreach ($runtime in @('win-x64', 'osx-x64', 'osx-arm64')) {
    Invoke-Dotnet @('restore', $project, '--runtime', $runtime, '--source', $nuget, '--ignore-failed-sources')
    $targetName = if ($runtime -eq 'win-x64') { 'windows-x64' } else { $runtime.Replace('osx-', 'macos-') }
    $target = Join-Path $release $targetName
    Invoke-Dotnet @('publish', $project, '--configuration', 'Release', '--runtime', $runtime,
        '--self-contained', 'true', '--no-restore', '-p:PublishSingleFile=true',
        '-p:IncludeNativeLibrariesForSelfExtract=true', '-o', $target)
}

$windows = Join-Path $release 'windows-x64'
# Windows-архив намеренно содержит только self-contained exe: PowerShell-скрипты
# встроены в него и при необходимости временно извлекаются в защищённый Program Files.
foreach ($file in @('install-monitor.cmd', 'uninstall-monitor.cmd', 'reset-autofix.cmd', 'run-fix.cmd', 'run-monitor.cmd',
        'AutoFix.Common.ps1', 'Manage-AutoFixTask.ps1', 'Roblox-CDN-AutoFix.ps1', 'Roblox-CDN-Monitor.ps1',
        'README.md', 'RobloxCDNAutoFix.pdb', 'build-release.ps1')) {
    Remove-Item -LiteralPath (Join-Path $windows $file) -Force -ErrorAction SilentlyContinue
}
foreach ($entry in @(Get-ChildItem -LiteralPath $windows -Force)) {
    if ($entry.Name -ne 'RobloxCDNAutoFix.exe') {
        if ($entry.PSIsContainer) { throw "Неожиданный каталог в Windows-релизе: $($entry.FullName)" }
        Remove-Item -LiteralPath $entry.FullName -Force
    }
}

foreach ($architecture in @('macos-x64', 'macos-arm64')) {
    $target = Join-Path $release $architecture
    Copy-Item -LiteralPath (Join-Path $root 'RELEASE.md') -Destination (Join-Path $target 'README.md') -Force
    foreach ($file in @('macos-fix.sh', 'macos-install-monitor.sh', 'macos-remove-monitor.sh')) {
        Copy-Item -LiteralPath (Join-Path $release $file) -Destination (Join-Path $target $file) -Force
    }
    foreach ($file in @('AutoFix.Common.ps1', 'Manage-AutoFixTask.ps1', 'Roblox-CDN-AutoFix.ps1', 'Roblox-CDN-Monitor.ps1', 'RobloxCDNAutoFix.pdb', 'build-release.ps1')) {
        Remove-Item -LiteralPath (Join-Path $target $file) -Force -ErrorAction SilentlyContinue
    }
}

$hashes = New-Object Collections.Generic.List[string]
foreach ($architecture in @('windows-x64', 'macos-x64', 'macos-arm64')) {
    $archive = Join-Path $release ($architecture + '.zip')
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $release $architecture) -DestinationPath $archive -CompressionLevel Optimal
    $hashes.Add(((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash + '  ' + $architecture + '.zip'))
}
[IO.File]::WriteAllLines((Join-Path $release 'SHA256SUMS.txt'), $hashes, [Text.Encoding]::ASCII)
Write-Host 'Релизы собраны:' -ForegroundColor Green
Get-ChildItem -LiteralPath $release -Filter '*.zip' | Select-Object Name, Length
