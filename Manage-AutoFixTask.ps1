# Управляет фоновой проверкой и полным сбросом изменений AutoFix.

[CmdletBinding()]
param(
    [ValidateSet("Install", "Uninstall", "Reset", "Status")]
    [string]$Action = "Install",

    [string]$ResultPath
)

$ErrorActionPreference = "Stop"

$TaskName = "Roblox CDN AutoFix"
$MonitorScriptPath = Join-Path $PSScriptRoot "Roblox-CDN-Monitor.ps1"
$MonitorLauncherPath = Join-Path $PSScriptRoot "run-monitor.cmd"
$Domain = "tr.rbxcdn.com"
$HostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$WorkDir = Join-Path $env:ProgramData "RobloxCDNAutoFix"
$BackupDir = Join-Path $WorkDir "backups"
$OriginalMappingPath = Join-Path $WorkDir "original-domain-mappings.txt"

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

function Get-DomainMappingLines {
    param([string[]]$Lines)

    $result = @()

    foreach ($line in $Lines) {
        if ($line -notmatch "^\s*(?<IP>\d{1,3}(?:\.\d{1,3}){3})\s+(?<Hosts>[^#]+)") {
            continue
        }

        $ip = $Matches.IP
        $hosts = @($Matches.Hosts.Trim() -split "\s+")
        $mapping = "{0}`t{1}" -f $ip, $Domain

        if (($hosts -contains $Domain) -and ($result -notcontains $mapping)) {
            $result += $mapping
        }
    }

    return $result
}

function Get-OriginalDomainMappings {
    if (Test-Path -LiteralPath $OriginalMappingPath) {
        return @([System.IO.File]::ReadAllLines($OriginalMappingPath))
    }

    if (-not (Test-Path -LiteralPath $BackupDir)) {
        return @()
    }

    $backups = @(Get-ChildItem -LiteralPath $BackupDir -Filter "hosts_*.bak" -File -ErrorAction SilentlyContinue | Sort-Object Name)

    foreach ($backup in $backups) {
        $backupLines = [System.IO.File]::ReadAllLines($backup.FullName)
        $hasManagedEntry = $null -ne ($backupLines | Where-Object { $_ -match "^\s*#\s*RobloxCDNAutoFix\b" } | Select-Object -First 1)

        if (-not $hasManagedEntry) {
            return @(Get-DomainMappingLines -Lines $backupLines)
        }
    }

    return @()
}

function Remove-ManagedDomainLines {
    param([string[]]$Lines)

    $result = @()

    foreach ($line in $Lines) {
        if ($line -match "^\s*#\s*RobloxCDNAutoFix\b") {
            continue
        }

        $content = $line
        $comment = ""
        $commentIndex = $line.IndexOf("#")

        if ($commentIndex -ge 0) {
            $content = $line.Substring(0, $commentIndex)
            $comment = $line.Substring($commentIndex).Trim()
        }

        if ($content -notmatch "^\s*(?<IP>\d{1,3}(?:\.\d{1,3}){3})\s+(?<Hosts>.+?)\s*$") {
            $result += $line
            continue
        }

        $ip = $Matches.IP
        $hosts = @($Matches.Hosts.Trim() -split "\s+")

        if ($hosts -notcontains $Domain) {
            $result += $line
            continue
        }

        $remainingHosts = @($hosts | Where-Object { $_ -ine $Domain })

        if ($remainingHosts.Count -gt 0) {
            $updatedLine = $ip + "`t" + ($remainingHosts -join " ")

            if (-not [string]::IsNullOrWhiteSpace($comment)) {
                $updatedLine += " " + $comment
            }

            $result += $updatedLine
        }
        elseif (-not [string]::IsNullOrWhiteSpace($comment)) {
            $result += $comment
        }
    }

    return $result
}

function Reset-AutoFixState {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($null -ne $task) {
        if ($task.State -eq "Running") {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        }

        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    if (Test-Path -LiteralPath $HostsPath) {
        $currentLines = [System.IO.File]::ReadAllLines($HostsPath)
        $hasManagedEntry = $null -ne ($currentLines | Where-Object { $_ -match "^\s*#\s*RobloxCDNAutoFix\b" } | Select-Object -First 1)
        $hasBackups = (Test-Path -LiteralPath $BackupDir) -and ($null -ne (Get-ChildItem -LiteralPath $BackupDir -Filter "hosts_*.bak" -File -ErrorAction SilentlyContinue | Select-Object -First 1))
        $shouldResetHosts = $hasManagedEntry -or (Test-Path -LiteralPath $OriginalMappingPath) -or $hasBackups

        if ($shouldResetHosts) {
            $originalMappings = @(Get-OriginalDomainMappings)
            $resetLines = @(Remove-ManagedDomainLines -Lines $currentLines)

            if ($originalMappings.Count -gt 0) {
                if (($resetLines.Count -gt 0) -and (-not [string]::IsNullOrWhiteSpace($resetLines[$resetLines.Count - 1]))) {
                    $resetLines += ""
                }

                $resetLines += $originalMappings
            }

            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

            try {
                [System.IO.File]::WriteAllLines($HostsPath, $resetLines, $utf8NoBom)
            }
            catch {
                try {
                    [System.IO.File]::WriteAllLines($HostsPath, $currentLines, $utf8NoBom)
                }
                catch {
                }

                throw
            }

            & ipconfig.exe /flushdns | Out-Null
        }
    }

    if (Test-Path -LiteralPath $WorkDir) {
        $programDataRoot = [System.IO.Path]::GetFullPath($env:ProgramData).TrimEnd("\")
        $resolvedWorkDir = [System.IO.Path]::GetFullPath($WorkDir).TrimEnd("\")
        $expectedWorkDir = Join-Path $programDataRoot "RobloxCDNAutoFix"

        if ($resolvedWorkDir -ine $expectedWorkDir) {
            throw "Небезопасный путь рабочей папки: $resolvedWorkDir"
        }

        Remove-Item -LiteralPath $resolvedWorkDir -Recurse -Force
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

if ($Action -eq "Reset") {
    Reset-AutoFixState
    Write-OperationResult -Message "Сброс завершён: задача удалена, исходная запись CDN восстановлена, DNS-кэш и служебные данные очищены." -Color "Green"
    exit 0
}

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
