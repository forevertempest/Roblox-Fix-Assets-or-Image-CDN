# Устанавливает защищённую копию и управляет задачей AutoFix.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Reset', 'Status')]
    [string]$Action = 'Install',
    [switch]$Elevated,
    [ValidateRange(1, 1440)]
    [int]$CooldownMinutes = 30,
    [ValidateSet('True', 'False')]
    [string]$AutoRepair = 'True',
    [string]$ProcessNames = 'RobloxPlayerBeta',
    [switch]$ProtectedSource
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$env:PATH = [Environment]::SystemDirectory
Set-Location -LiteralPath ([Environment]::SystemDirectory)
. (Join-Path $PSScriptRoot 'AutoFix.Common.ps1')

if ($ProtectedSource) {
    Assert-ProtectedPath $PSScriptRoot
    $expectedSourceFiles = @($script:RuntimeFiles + 'Manage-AutoFixTask.ps1')
    if ($Action -in @('Status', 'Uninstall')) { $expectedSourceFiles = @($expectedSourceFiles | Where-Object { $_.EndsWith('.ps1') }) }
    foreach ($sourceEntry in @(Get-ChildItem -LiteralPath $PSScriptRoot -Force)) {
        if ($sourceEntry.Name -notin $expectedSourceFiles) {
            throw "В защищённой staging-папке найден неожиданный файл: $($sourceEntry.FullName)"
        }
        Assert-NoReparsePoint $sourceEntry.FullName
    }
    foreach ($sourceName in $expectedSourceFiles) {
        $sourcePath = Join-Path $PSScriptRoot $sourceName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "В защищённой staging-папке отсутствует файл: $sourceName"
        }
        Assert-ProtectedPath $sourcePath
    }
}

if (-not (Test-IsAdministrator)) {
    if ($Elevated) { throw 'Требуются права администратора.' }
    try {
        if ($ProcessNames -notmatch '^[A-Za-z0-9_.-]{1,80}(,[A-Za-z0-9_.-]{1,80}){0,7}$') { throw 'Некорректный список процессов.' }
        $protectedArgument = if ($ProtectedSource) { ' -ProtectedSource' } else { '' }
        $arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1} -Elevated -CooldownMinutes {2} -AutoRepair {3} -ProcessNames "{4}"{5}' -f $PSCommandPath, $Action, $CooldownMinutes, $AutoRepair, $ProcessNames, $protectedArgument)
        $process = Start-Process -FilePath $script:PowerShellExe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
        $resultLog = Join-Path $script:DataRoot 'Installer.log'
        if (Test-Path -LiteralPath $resultLog) { Get-Content -LiteralPath $resultLog -Encoding UTF8 -Tail 1 }
        if ($process.ExitCode -ne 0) { Write-Host 'Операция не завершена. Код:' $process.ExitCode }
        exit $process.ExitCode
    }
    catch { Write-Host $_.Exception.Message; exit 1 }
}
$autoRepairEnabled = [bool]::Parse($AutoRepair)
if ($Action -eq 'Reset') {
    $native = Join-Path $PSScriptRoot 'AutoFixV2.exe'
    if (-not (Test-Path -LiteralPath $native)) { throw 'Используй windows-x64.exe reset для безопасного сброса v2.' }
    & $native --restore
    if ($LASTEXITCODE -ne 0) { throw 'Сброс hosts не завершён; удаление отменено.' }
    $Action = 'Uninstall'
}
Import-Module (Join-Path $PSHOME 'Modules\ScheduledTasks\ScheduledTasks.psd1') -ErrorAction Stop

function Get-AutoFixTask {
    return @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -eq $script:TaskName }) | Select-Object -First 1
}
function Protect-AutoFixTask {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $task = $scheduler.GetFolder('\').GetTask($script:TaskName)
    $task.SetSecurityDescriptor('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)', 0x10)
}
function Stop-AutoFixTask {
    $task = Get-AutoFixTask
    if ($null -eq $task) { return }
    Disable-ScheduledTask -TaskName $script:TaskName -TaskPath '\' | Out-Null
    Stop-ScheduledTask -TaskName $script:TaskName -TaskPath '\'
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ((Get-AutoFixTask).State -ne 'Running') { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'Не удалось остановить задачу.'
}
$operationLock = $null
$installationLock = $null
$previousXml = $null
$registered = $false
$newRelease = $null
$previousRelease = $null
$taskWasTouched = $false
$settingsBefore = $null
$settingsChanged = $false
try {
    Initialize-AutoFixData
    $installationLock = Enter-AutoFixLock -Name 'installation.lock'
    if ($Action -eq 'Status') {
        $task = Get-AutoFixTask
        if ($null -eq $task) {
            Write-Host 'Автоматическая проверка не установлена. Для установки выбери пункт 2 в главном меню.'
            exit 0
        }
        Write-Host ("Состояние автопроверки: " + $task.State)
        Write-Host 'CDN проверяется при запуске Roblox. Периодических сетевых проверок нет.'
        Write-Host ($task.Actions | Format-List Execute, Arguments, WorkingDirectory | Out-String)
        Write-RotatingLog 'Installer.log' ("Состояние задачи: " + $task.State)
        exit 0
    }
    $oldTask = Get-AutoFixTask
    if ($null -ne $oldTask) { Protect-AutoFixTask }
    if ($Action -eq 'Install' -and $null -ne $oldTask) {
        $expectedPrefix = (Join-Path $script:InstallRoot 'versions') + '\'
        if ($oldTask.Actions.Count -eq 1 -and $oldTask.Actions[0].Execute -eq $script:PowerShellExe -and
            $oldTask.Actions[0].WorkingDirectory -and
            $oldTask.Actions[0].WorkingDirectory.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            $oldTask.Actions[0].Arguments -ceq ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Watch' -f (Join-Path $oldTask.Actions[0].WorkingDirectory 'Roblox-CDN-Monitor.ps1'))) {
            try {
                Assert-Release $oldTask.Actions[0].WorkingDirectory
                $previousRelease = $oldTask.Actions[0].WorkingDirectory
                $previousXml = Export-ScheduledTask -TaskName $script:TaskName -TaskPath '\'
            }
            catch { Write-RotatingLog 'Installer.log' 'Предыдущая копия повреждена: обновление без автоматического возврата к ней.' }
        }
    }
    $operationLock = Enter-AutoFixLock
    $taskWasTouched = $true
    Stop-AutoFixTask
    if ($Action -eq 'Install') {
        if (Test-Path -LiteralPath $script:MonitorSettingsPath) {
            Assert-ProtectedPath $script:MonitorSettingsPath
            $settingsBefore = [IO.File]::ReadAllBytes($script:MonitorSettingsPath)
        }
        $settingsChanged = $true
        Write-MonitorSettings -CooldownMinutes $CooldownMinutes -AutoRepair $autoRepairEnabled -ProcessNames $ProcessNames
    }
    if ($Action -eq 'Uninstall') {
        if ($null -ne (Get-AutoFixTask)) {
            Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Confirm:$false
        }
        Remove-ProtectedTree $script:InstallRoot
        Write-RotatingLog 'Installer.log' ("$Action завершён. Защищённая копия удалена; резервные копии сохранены в " + $script:DataRoot)
        Write-Host 'Автопроверка удалена. Записи hosts не изменены.'
        Write-Host ("Резервные копии и журналы сохранены: " + $script:DataRoot)
        exit 0
    }
    Assert-ProtectedPath ([IO.Path]::GetDirectoryName($script:InstallRoot))
    New-ProtectedDirectory $script:InstallRoot
    $versions = Join-Path $script:InstallRoot 'versions'
    New-ProtectedDirectory $versions
    $newRelease = Join-Path $versions ([Guid]::NewGuid().ToString('N'))
    New-ProtectedDirectory $newRelease
    $manifest = [ordered]@{}
    foreach ($name in $script:RuntimeFiles) {
        $source = Join-Path $PSScriptRoot $name
        Assert-NoReparsePoint $source
        $sourceStream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $limit = if ($name -eq 'AutoFixV2.exe') { 150MB } else { 1MB }
            if ($sourceStream.Length -gt $limit) { throw "Слишком большой файл: $name" }
            $destination = Join-Path $newRelease $name
            $targetStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $sourceStream.CopyTo($targetStream); $targetStream.Flush($true) }
            finally { $targetStream.Dispose() }
        }
        finally { $sourceStream.Dispose() }
        if ($name.EndsWith('.ps1')) {
            $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseFile($destination, [ref]$null, [ref]$parseErrors) | Out-Null
            if ($parseErrors.Count -gt 0) { throw "Ошибка синтаксиса: $name" }
        }
        if ($name.EndsWith('.json')) { Get-Content -LiteralPath $destination -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null }
        $manifest[$name] = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    }
    [IO.File]::WriteAllText((Join-Path $newRelease 'manifest.json'), ($manifest | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Assert-Release $newRelease
    $monitorPath = Join-Path $newRelease 'Roblox-CDN-Monitor.ps1'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Watch' -f $monitorPath
    $taskAction = New-ScheduledTaskAction -Execute $script:PowerShellExe -Argument $arguments -WorkingDirectory $newRelease
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 7 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Action $taskAction -Principal $principal -Trigger $trigger -Settings $settings -Description 'Проверка CDN по событию запуска Roblox; защищённая установка.' -Force | Out-Null
    $registered = $true
    Protect-AutoFixTask
    $operationLock.Dispose()
    $operationLock = $null
    Start-ScheduledTask -TaskName $script:TaskName -TaskPath '\'
    Start-Sleep -Seconds 3
    if ((Get-AutoFixTask).State -ne 'Running') { throw 'Наблюдатель завершился при запуске. См. RobloxCDNMonitor.log.' }
    foreach ($release in @(Get-ChildItem -LiteralPath $versions -Directory)) {
        if ($release.Name -match '^[a-f0-9]{32}$' -and $release.FullName -notin @($newRelease, $previousRelease)) {
            try { Remove-ProtectedTree $release.FullName }
            catch { Write-RotatingLog 'Installer.log' ('Старая версия оставлена: ' + $_.Exception.Message) }
        }
    }
    Write-RotatingLog 'Installer.log' 'Установка завершена. Перезапусти Roblox для проверки CDN. Исходная папка больше не используется задачей.'
    Write-Host 'Автопроверка установлена. Перезапусти Roblox для проверки CDN.'
    Write-Host ("Автоисправление: {0}; пауза между исправлениями: {1} мин." -f $autoRepairEnabled, $CooldownMinutes)
    Write-Host ("Отслеживаемые процессы: " + $ProcessNames)
}
catch {
    $failure = $_.Exception.Message
    if ($Action -eq 'Install') {
        try {
            if ($registered) { Stop-AutoFixTask; Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Confirm:$false }
            if ($settingsChanged) {
                Assert-NoReparsePoint $script:MonitorSettingsPath
                if ($null -ne $settingsBefore) {
                    $temporarySettings = Join-Path $script:DataRoot ([Guid]::NewGuid().ToString('N') + '.tmp')
                    try {
                        [IO.File]::WriteAllBytes($temporarySettings, $settingsBefore)
                        if (Test-Path -LiteralPath $script:MonitorSettingsPath) {
                            Assert-ProtectedPath $script:MonitorSettingsPath
                            [IO.File]::Replace($temporarySettings, $script:MonitorSettingsPath, [NullString]::Value)
                        }
                        else { [IO.File]::Move($temporarySettings, $script:MonitorSettingsPath) }
                    }
                    finally { if ([IO.File]::Exists($temporarySettings)) { [IO.File]::Delete($temporarySettings) } }
                }
                elseif (Test-Path -LiteralPath $script:MonitorSettingsPath) {
                    Assert-ProtectedPath $script:MonitorSettingsPath
                    [IO.File]::Delete($script:MonitorSettingsPath)
                }
            }
            if ($previousXml -and $taskWasTouched) {
                Register-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Xml $previousXml -Force | Out-Null
                Protect-AutoFixTask
                Start-ScheduledTask -TaskName $script:TaskName -TaskPath '\'
            }
            if ($newRelease) { Remove-ProtectedTree $newRelease }
        }
        catch { $failure += ' Не удалось восстановить предыдущую задачу: ' + $_.Exception.Message }
    }
    try { Write-RotatingLog 'Installer.log' ("Ошибка: " + $failure) } catch { }
    Write-Host $failure -ForegroundColor Red
    exit 1
}
finally {
    if ($null -ne $operationLock) { $operationLock.Dispose() }
    if ($null -ne $installationLock) { $installationLock.Dispose() }
}
