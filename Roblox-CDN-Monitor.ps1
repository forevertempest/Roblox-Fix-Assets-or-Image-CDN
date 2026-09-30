[CmdletBinding()]
param([switch]$Watch)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$env:PATH = [Environment]::SystemDirectory
Set-Location -LiteralPath ([Environment]::SystemDirectory)
. (Join-Path $PSScriptRoot 'AutoFix.Common.ps1')
if (-not $Watch) { throw 'Для ручной проверки используй --diagnose или --repair.' }
Assert-Release $PSScriptRoot
Initialize-AutoFixData
$bundleCache = Join-Path $script:DataRoot 'dotnet-bundle'
New-ProtectedDirectory $bundleCache
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = $bundleCache
$settings = Read-MonitorSettings
Import-Module (Join-Path $PSHOME 'Modules\CimCmdlets\CimCmdlets.psd1')
$source = 'RobloxCDNAutoFixV2.ProcessStart'
$query = New-RobloxProcessStartQuery $settings.ProcessNames
Register-CimIndicationEvent -Namespace root/cimv2 -Query $query -SourceIdentifier $source | Out-Null
$lastRepair = [DateTime]::MinValue
$statePath = Join-Path $script:DataRoot 'last-monitor-repair.txt'
if (Test-Path -LiteralPath $statePath) {
    Assert-ProtectedPath $statePath
    $saved = [DateTime]::MinValue
    if ([DateTime]::TryParse([IO.File]::ReadAllText($statePath), [ref]$saved) -and $saved.ToUniversalTime() -le [DateTime]::UtcNow) { $lastRepair = $saved.ToUniversalTime() }
}
function Invoke-NativeCheck {
    param([string]$Mode)
    Assert-Release $PSScriptRoot
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $PSScriptRoot 'AutoFixV2.exe'
    $start.Arguments = $Mode + ' --system-settings'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $start.WorkingDirectory = $PSScriptRoot
    $process = [Diagnostics.Process]::Start($start)
    try {
        $errors = $process.StandardError.ReadToEndAsync()
        while ($null -ne ($line = $process.StandardOutput.ReadLine())) {
            Write-RotatingLog 'RobloxCDNMonitor.log' $line
        }
        $process.WaitForExit()
        if ($errors.GetAwaiter().GetResult()) { Write-RotatingLog 'RobloxCDNMonitor.log' 'Проверка завершилась с ошибкой.' }
        return $process.ExitCode
    }
    finally { $process.Dispose() }
}
Write-RotatingLog 'RobloxCDNMonitor.log' 'AutoFix v2 готов. Сеть проверяется только при запуске Roblox.'
try {
    while ($true) {
        $event = Wait-Event -SourceIdentifier $source
        Remove-Event -EventIdentifier $event.EventIdentifier
        try {
            if ((Invoke-NativeCheck '--diagnose') -ne 0 -and $settings.AutoRepair) {
                if (([DateTime]::UtcNow - $lastRepair).TotalMinutes -ge $settings.CooldownMinutes) {
                    $lastRepair = [DateTime]::UtcNow
                    Assert-NoReparsePoint $statePath
                    if (Test-Path -LiteralPath $statePath) { Assert-ProtectedPath $statePath }
                    [IO.File]::WriteAllText($statePath, $lastRepair.ToString('o'))
                    $result = Invoke-NativeCheck '--repair'
                    Write-RotatingLog 'RobloxCDNMonitor.log' ('Repair exit code: ' + $result)
                }
                else { Write-RotatingLog 'RobloxCDNMonitor.log' 'Повторный ремонт отложен до окончания cooldown.' }
            }
        }
        catch { Write-RotatingLog 'RobloxCDNMonitor.log' ('Проверка не завершена: ' + $_.Exception.Message) }
        finally { Get-Event -SourceIdentifier $source -ErrorAction SilentlyContinue | Remove-Event }
    }
}
finally { Unregister-Event -SourceIdentifier $source }
