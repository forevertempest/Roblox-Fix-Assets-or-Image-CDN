# Устанавливает и удаляет фоновую проверку через Планировщик заданий Windows.

[CmdletBinding()]
param(
    [ValidateSet("Install", "Uninstall", "Status")]
    [string]$Action = "Install",

    [string]$ResultPath
)

$ErrorActionPreference = "Stop"

$TaskName = "Roblox CDN AutoFix"
$MonitorScriptPath = Join-Path $PSScriptRoot "Roblox-CDN-Monitor.ps1"
$MonitorLauncherPath = Join-Path $PSScriptRoot "run-monitor.cmd"

function Write-OperationResult {
    param(
        [string]$Message,
        [string]$Color = "White"
    )

    Write-Host $Message -ForegroundColor $Color

    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        [System.IO.File]::WriteAllText($ResultPath, $Message, (New-Object System.Text.UTF8Encoding($true)))
    }
}

trap {
    $errorMessage = "Ошибка: {0}" -f $_.Exception.Message
    Write-OperationResult -Message $errorMessage -Color "Red"
    exit 1
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-AsAdministrator {
    if (Test-IsAdministrator) {
        return
    }

    $elevationResultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("RobloxCDNAutoFix_{0}.txt" -f [Guid]::NewGuid().ToString("N"))
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1} -ResultPath "{2}"' -f $PSCommandPath, $Action, $elevationResultPath

    try {
        $process = Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -ArgumentList $arguments `
            -Wait `
            -PassThru

        if (Test-Path -LiteralPath $elevationResultPath) {
            Get-Content -LiteralPath $elevationResultPath
            Remove-Item -LiteralPath $elevationResultPath -Force
        }
        elseif ($process.ExitCode -ne 0) {
            Write-Host ("Операция завершилась с кодом {0}, но подробности получить не удалось." -f $process.ExitCode) -ForegroundColor Red
        }

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
        Write-OperationResult -Message "Автоматическая проверка не установлена."
        exit 1
    }

    Write-OperationResult -Message ("Задача установлена. Состояние: {0}" -f $task.State) -Color "Green"
    exit 0
}

Restart-AsAdministrator

if ($Action -eq "Uninstall") {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($null -eq $task) {
        Write-OperationResult -Message "Автоматическая проверка уже удалена." -Color "Green"
        exit 0
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-OperationResult -Message "Автоматическая проверка удалена." -Color "Green"
    exit 0
}

if (-not (Test-Path -LiteralPath $MonitorScriptPath)) {
    throw "Не найден файл монитора: $MonitorScriptPath"
}

if (-not (Test-Path -LiteralPath $MonitorLauncherPath)) {
    throw "Не найден файл запуска монитора: $MonitorLauncherPath"
}

$taskArguments = '/d /c ""{0}" --scheduled"' -f $MonitorLauncherPath
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

Write-OperationResult -Message "Автоматическая проверка установлена. Roblox закрыт — сетевых запросов нет; Roblox запущен — CDN проверяется раз в пять минут." -Color "Green"
