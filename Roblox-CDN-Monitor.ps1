# Лёгкий монитор CDN: пока Roblox не запущен, сетевых запросов не делает.

[CmdletBinding()]
param(
    [int]$CooldownMinutes = 30
)

$ErrorActionPreference = "Stop"

$Domain = "tr.rbxcdn.com"
$FixScriptPath = Join-Path $PSScriptRoot "Roblox-CDN-AutoFix.ps1"
$WorkDir = Join-Path $env:ProgramData "RobloxCDNAutoFix"
$StatePath = Join-Path $WorkDir "last-monitor-repair.txt"
$LogPath = Join-Path $WorkDir "RobloxCDNMonitor.log"
$RobloxProcessNames = @(
    "RobloxPlayerBeta",
    "RobloxPlayerLauncher"
)

function Write-MonitorLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Test-RobloxRunning {
    foreach ($processName in $RobloxProcessNames) {
        if ($null -ne (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            return $true
        }
    }

    return $false
}

function Test-CdnAvailable {
    if ($null -eq (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
        return $false
    }

    $curlArgs = @(
        "--silent",
        "--show-error",
        "--output", "NUL",
        "--write-out", "%{http_code}",
        "--noproxy", "*",
        "--ipv4",
        "--connect-timeout", "3",
        "--max-time", "6",
        ("https://{0}/" -f $Domain)
    )

    try {
        $output = & curl.exe @curlArgs 2>$null
        $code = ($output | Select-Object -Last 1).ToString().Trim()

        return (
            ($LASTEXITCODE -eq 0) -and
            ($code -match "^[0-9]{3}$") -and
            ($code -ne "000")
        )
    }
    catch {
        return $false
    }
}

function Test-RepairCooldown {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $false
    }

    try {
        $lastRepair = [DateTime]::Parse([System.IO.File]::ReadAllText($StatePath))
        return ((Get-Date) - $lastRepair).TotalMinutes -lt $CooldownMinutes
    }
    catch {
        return $false
    }
}

if (-not (Test-RobloxRunning)) {
    exit 0
}

if (Test-CdnAvailable) {
    exit 0
}

# Повторная проверка отсеивает короткие сетевые сбои и переключения Wi-Fi.
Start-Sleep -Seconds 3

if (Test-CdnAvailable) {
    exit 0
}

if (Test-RepairCooldown) {
    exit 0
}

if (-not (Test-Path -LiteralPath $FixScriptPath)) {
    Write-MonitorLog ("Скрипт исправления не найден: {0}" -f $FixScriptPath) "ERROR"
    exit 2
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
[System.IO.File]::WriteAllText($StatePath, (Get-Date).ToString("O"))

Write-MonitorLog ("Roblox запущен, а {0} дважды не прошёл HTTPS-проверку. Запускаю исправление." -f $Domain) "WARN"

& powershell.exe `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File $FixScriptPath `
    -Quiet

$fixExitCode = $LASTEXITCODE

if ($fixExitCode -eq 0) {
    Write-MonitorLog "Автоматическое исправление завершилось успешно."
}
else {
    Write-MonitorLog ("Скрипт исправления завершился с кодом {0}." -f $fixExitCode) "ERROR"
}

exit $fixExitCode
