# Проверяет CDN по событию запуска игры или по ручному запросу.
[CmdletBinding()]
param([switch]$Watch, [ValidateRange(1, 1440)][int]$CooldownMinutes = 30)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$env:PATH = [Environment]::SystemDirectory
Set-Location -LiteralPath ([Environment]::SystemDirectory)
. (Join-Path $PSScriptRoot 'AutoFix.Common.ps1')
$script:AutoRepair = $true

function Test-CdnAvailable {
    if (-not (Test-Path -LiteralPath $script:CurlExe)) { throw 'Системный curl.exe не найден.' }
    $curlArgs = @('--disable', '--proto', '=https', '--silent', '--output', 'NUL',
        '--write-out', '%{http_code}', '--noproxy', '*', '--ipv4',
        '--connect-timeout', '3', '--max-time', '6', 'https://tr.rbxcdn.com/')
    $output = & $script:CurlExe @curlArgs
    return ($LASTEXITCODE -eq 0 -and ($output -join '').Trim() -match '^[1-5][0-9]{2}$')
}

function Invoke-CdnCheck {
    if (Test-CdnAvailable) { Write-Host 'CDN доступен.'; return 0 }
    Start-Sleep -Seconds 3
    if (Test-CdnAvailable) { Write-Host 'CDN доступен после повторной проверки.'; return 0 }
    if (-not (Test-IsAdministrator)) {
        Write-Host 'CDN недоступен. Запусти run-fix.cmd или установи мониторинг.'
        return 1
    }
    if (-not $script:AutoRepair) {
        Write-RotatingLog 'RobloxCDNMonitor.log' 'CDN недоступен; автоматическое исправление отключено в настройках.'
        Write-Host 'CDN недоступен; автоматическое исправление отключено в настройках.'
        return 3
    }
    $operationLock = Enter-AutoFixLock
    try {
        $statePath = Join-Path $script:DataRoot 'last-monitor-repair.txt'
        Assert-NoReparsePoint $statePath
        if (Test-Path -LiteralPath $statePath) {
            Assert-ProtectedPath $statePath
            $lastRepair = [DateTime]::MinValue
            if ([DateTime]::TryParse([IO.File]::ReadAllText($statePath), [ref]$lastRepair) -and
                ([DateTime]::UtcNow - $lastRepair.ToUniversalTime()).TotalMinutes -lt $CooldownMinutes) {
                Write-Host 'CDN недоступен; повторное исправление отложено на время cooldown.'
                return 2
            }
        }
        [IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))
        Write-RotatingLog 'RobloxCDNMonitor.log' 'Две ошибки HTTPS; запускается исправление.'
    }
    finally { $operationLock.Dispose() }
    if ($Watch) { Assert-Release $PSScriptRoot }
    $fixPath = Join-Path $PSScriptRoot 'Roblox-CDN-AutoFix.ps1'
    & $script:PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fixPath -Quiet | Out-Host
    $result = $LASTEXITCODE
    Write-RotatingLog 'RobloxCDNMonitor.log' ("Код завершения исправления: " + $result)
    return $result
}

try {
    if ($Watch) {
        if (-not (Test-IsAdministrator)) { throw 'Наблюдатель должен запускаться установленной задачей.' }
        Assert-Release $PSScriptRoot
        Initialize-AutoFixData
        $settings = Read-MonitorSettings
        $CooldownMinutes = $settings.CooldownMinutes
        $script:AutoRepair = $settings.AutoRepair
        Import-Module (Join-Path $PSHOME 'Modules\CimCmdlets\CimCmdlets.psd1')
        $source = 'RobloxCDNAutoFix.ProcessStart'
        Register-CimIndicationEvent -Namespace root/cimv2 -Query "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'RobloxPlayerBeta.exe'" -SourceIdentifier $source | Out-Null
        Write-RotatingLog 'RobloxCDNMonitor.log' 'Наблюдатель готов. Ожидание запуска Roblox.'
        try {
            while ($true) {
                $event = Wait-Event -SourceIdentifier $source
                Remove-Event -EventIdentifier $event.EventIdentifier
                Assert-Release $PSScriptRoot
                try { Invoke-CdnCheck | Out-Null }
                catch { Write-RotatingLog 'RobloxCDNMonitor.log' ('Проверка не завершена: ' + $_.Exception.Message) }
                finally { Get-Event -SourceIdentifier $source -ErrorAction SilentlyContinue | Remove-Event }
            }
        }
        finally { Unregister-Event -SourceIdentifier $source }
    }
    else {
        if (-not (Get-Process -Name RobloxPlayerBeta, RobloxPlayerLauncher -ErrorAction SilentlyContinue)) {
            Write-Host 'Roblox не запущен. Проверка не требуется.'
            exit 0
        }
        if (Test-IsAdministrator) { Initialize-AutoFixData }
        exit (Invoke-CdnCheck)
    }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if (Test-IsAdministrator) {
        try { Write-RotatingLog 'RobloxCDNMonitor.log' $_.Exception.Message } catch { }
    }
    exit 1
}
