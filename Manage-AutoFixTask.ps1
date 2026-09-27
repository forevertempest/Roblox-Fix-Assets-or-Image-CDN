# Устанавливает и удаляет фоновую проверку через Планировщик заданий Windows.

[CmdletBinding()]
param(
    [ValidateSet("Install", "Uninstall", "Status")]
    [string]$Action = "Install"
)

$ErrorActionPreference = "Stop"

$TaskName = "Roblox CDN AutoFix"
$MonitorScriptPath = Join-Path $PSScriptRoot "Roblox-CDN-Monitor.ps1"
$MonitorLauncherPath = Join-Path $PSScriptRoot "run-monitor.cmd"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-AsAdministrator {
    if (Test-IsAdministrator) {
        return
    }

    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $PSCommandPath, $Action

    try {
        $process = Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -ArgumentList $arguments `
            -Wait `
            -PassThru

        exit $process.ExitCode
    }
    catch {
        Write-Host "Не удалось получить права администратора." -ForegroundColor Red
        Write-Host $_.Exception.Message
        exit 1
    }
}

if ($Action -eq "Status") {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($null -eq $task) {
        Write-Host "Автоматическая проверка не установлена."
        exit 1
    }

    Write-Host ("Задача установлена. Состояние: {0}" -f $task.State) -ForegroundColor Green
    exit 0
}

Restart-AsAdministrator

if ($Action -eq "Uninstall") {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($null -eq $task) {
        Write-Host "Автоматическая проверка уже удалена."
        exit 0
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Автоматическая проверка удалена." -ForegroundColor Green
    exit 0
}

if (-not (Test-Path -LiteralPath $MonitorScriptPath)) {
    throw "Не найден файл монитора: $MonitorScriptPath"
}

if (-not (Test-Path -LiteralPath $MonitorLauncherPath)) {
    throw "Не найден файл запуска монитора: $MonitorLauncherPath"
}

$taskArguments = '/d /c ""{0}""' -f $MonitorLauncherPath
$taskAction = New-ScheduledTaskAction `
    -Execute (Join-Path $env:SystemRoot "System32\cmd.exe") `
    -Argument $taskArguments `
    -WorkingDirectory $PSScriptRoot

# Задача просыпается раз в пять минут, но сам монитор обычно завершается почти мгновенно.
$taskTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$taskSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3) `
    -MultipleInstances IgnoreNew `
    -Priority 7

Register-ScheduledTask `
    -TaskName $TaskName `
    -Description "Проверяет Roblox CDN только во время работы Roblox и при необходимости обновляет hosts." `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -Settings $taskSettings `
    -User "SYSTEM" `
    -RunLevel Highest `
    -Force | Out-Null

Write-Host "Автоматическая проверка установлена." -ForegroundColor Green
Write-Host "Roblox не запущен: монитор не обращается к сети."
Write-Host "Roblox запущен: CDN проверяется раз в пять минут."
