[CmdletBinding()]
param([ValidateSet('win-x64', 'win-arm64')][string[]]$Runtime = @('win-x64', 'win-arm64'))

$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
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

[IO.Directory]::CreateDirectory($release) | Out-Null
$hashes = @()
foreach ($architecture in $Runtime) {
$publish = Join-Path $root ('console\obj\publish\' + $architecture)
Invoke-Dotnet @('restore', $project, '--runtime', $architecture, '--source', $nuget, '--ignore-failed-sources')
Invoke-Dotnet @('publish', $project, '--configuration', 'Release', '--runtime', $architecture,
    '--self-contained', 'true', '--no-restore', '-p:PublishSingleFile=true',
    '-p:IncludeNativeLibrariesForSelfExtract=true', '-o', $publish)

$publishedExecutable = Join-Path $publish 'RobloxCDNAutoFix.exe'
if (-not (Test-Path -LiteralPath $publishedExecutable -PathType Leaf)) {
    throw 'Сборка не создала исполняемый файл.'
}
$fileName = $architecture.Replace('win-', 'windows-') + '.exe'
$standaloneExecutable = Join-Path $release $fileName
Copy-Item -LiteralPath $publishedExecutable -Destination $standaloneExecutable -Force
$hashes += (Get-FileHash -LiteralPath $standaloneExecutable -Algorithm SHA256).Hash + '  ' + $fileName
Get-Item -LiteralPath $standaloneExecutable | Select-Object Name, Length
}
[IO.File]::WriteAllText((Join-Path $release 'SHA256SUMS.txt'), ($hashes -join [Environment]::NewLine) + [Environment]::NewLine, [Text.Encoding]::ASCII)
Write-Host 'Релиз готов для загрузки в GitHub Releases:' -ForegroundColor Green
