[CmdletBinding()]
param([switch]$Quiet, [switch]$Diagnose, [switch]$DryRun, [switch]$Restore, [switch]$Force)
$ErrorActionPreference = 'Stop'
$executable = Join-Path $PSScriptRoot 'AutoFixV2.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    $executable = Join-Path $PSScriptRoot 'release\windows-x64.exe'
}
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Сначала собери v2 через build-release.ps1.' }
$arguments = @('--repair')
if ($Diagnose) { $arguments = @('--diagnose') }
if ($DryRun) { $arguments = @('--dry-run') }
if ($Restore) { $arguments = @('--restore') }
if ($Force) { $arguments += '--force' }
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { $arguments += '--system-settings' }
& $executable @arguments
exit $LASTEXITCODE
