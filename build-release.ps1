[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$project = Join-Path $root 'console\RobloxCDNAutoFix.Console.csproj'
$release = Join-Path $root 'release'
$publish = Join-Path $root 'console\obj\publish\win-x64'
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source
$nuget = 'https://api.nuget.org/v3/index.json'

function Invoke-Dotnet {
    param([string[]]$Arguments)
    & $dotnet @Arguments
    if ($LASTEXITCODE -ne 0) { throw "dotnet завершился с кодом $LASTEXITCODE." }
}

Invoke-Dotnet @('restore', $project, '--runtime', 'win-x64', '--source', $nuget, '--ignore-failed-sources')
Invoke-Dotnet @('publish', $project, '--configuration', 'Release', '--runtime', 'win-x64',
    '--self-contained', 'true', '--no-restore', '-p:PublishSingleFile=true',
    '-p:IncludeNativeLibrariesForSelfExtract=true', '-o', $publish)

$publishedExecutable = Join-Path $publish 'RobloxCDNAutoFix.exe'
if (-not (Test-Path -LiteralPath $publishedExecutable -PathType Leaf)) {
    throw 'Сборка не создала исполняемый файл.'
}
[IO.Directory]::CreateDirectory($release) | Out-Null
$standaloneExecutable = Join-Path $release 'windows-x64.exe'
Copy-Item -LiteralPath $publishedExecutable -Destination $standaloneExecutable -Force
$hashLine = (Get-FileHash -LiteralPath $standaloneExecutable -Algorithm SHA256).Hash + '  windows-x64.exe'
[IO.File]::WriteAllText((Join-Path $release 'SHA256SUMS.txt'), $hashLine + [Environment]::NewLine, [Text.Encoding]::ASCII)
Write-Host 'Релиз готов для загрузки в GitHub Releases:' -ForegroundColor Green
Get-Item -LiteralPath $standaloneExecutable, (Join-Path $release 'SHA256SUMS.txt') | Select-Object Name, Length
