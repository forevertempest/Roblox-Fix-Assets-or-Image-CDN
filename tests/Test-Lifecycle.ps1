# Интеграционная проверка удаляет мониторинг и устанавливает его заново.
[CmdletBinding()]
param([switch]$Elevated)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'AutoFix.Common.ps1')
if (-not (Test-IsAdministrator)) {
    if ($Elevated) { throw 'Administrator privileges are required.' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated' -f $PSCommandPath
    $process = Start-Process -FilePath $script:PowerShellExe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
    $report = Join-Path $script:DataRoot 'Security-test-results.txt'
    if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Encoding UTF8 }
    exit $process.ExitCode
}
$reportLines = New-Object 'Collections.Generic.List[string]'
$fixture = $null
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $reportLines.Add("PASS: $Name")
}
function Run-Manager([string]$Mode, [string]$Source = $root, [int]$Expected = 0) {
    if ($Source -eq $root) {
        $argument = if ($Mode -eq 'Uninstall') { 'remove' } else { 'install' }
        & (Join-Path $root 'release\windows-x64.exe') monitor $argument | Out-Host
    }
    else {
        & $script:PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Source 'Manage-AutoFixTask.ps1') -Action $Mode | Out-Host
    }
    Check ($LASTEXITCODE -eq $Expected) "$Mode exit code $Expected"
}
$exitCode = 1
try {
    Initialize-AutoFixData
    $hostHash = (Get-FileHash -LiteralPath $script:HostsPath).Hash
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $root 'Roblox-CDN-AutoFix.ps1')).Hash
    Run-Manager 'Uninstall'
    Run-Manager 'Uninstall'
    Import-Module (Join-Path $PSHOME 'Modules\ScheduledTasks\ScheduledTasks.psd1')
    Check (-not (Test-Path -LiteralPath $script:InstallRoot)) 'installed tree removed'
    Check (@(Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $script:TaskName).Count -eq 0) 'task removed'
    Check ((Get-FileHash -LiteralPath (Join-Path $root 'Roblox-CDN-AutoFix.ps1')).Hash -eq $sourceHash) 'repository unchanged'
    Run-Manager 'Install'
    $task = Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\'
    $firstRelease = $task.Actions[0].WorkingDirectory
    Assert-Release $firstRelease
    Check ($task.State -eq 'Running') 'watcher running'
    $principalSid = $task.Principal.UserId
    if ($principalSid -notmatch '^S-1-') {
        $principalSid = (New-Object Security.Principal.NTAccount($principalSid)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    Check ($principalSid -eq 'S-1-5-18') 'SYSTEM principal'
    Check ($task.Principal.RunLevel -eq 'Highest') 'highest run level'
    Check ($task.Actions[0].Execute -eq $script:PowerShellExe) 'absolute system PowerShell'
    Check ($task.Actions[0].Arguments -ceq ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Watch' -f (Join-Path $firstRelease 'Roblox-CDN-Monitor.ps1'))) 'quoted protected script action'
    Run-Manager 'Install'
    $current = Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\'
    Check ($current.Actions[0].WorkingDirectory -ne $firstRelease) 'repeat install switches to new verified release'
    Check (@(Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $script:TaskName).Count -eq 1) 'no duplicate tasks'
    $heldRepair = Enter-AutoFixLock
    try { Run-Manager -Mode 'Uninstall' -Expected 1 }
    finally { $heldRepair.Dispose() }
    Check ((Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\').State -eq 'Running') 'busy repair prevents uninstall without stopping watcher'
    $settingsHash = (Get-FileHash -LiteralPath $script:MonitorSettingsPath).Hash

    $fixture = Join-Path $PSScriptRoot ('.fixtures_' + [Guid]::NewGuid().ToString('N') + ' space & bang!')
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    foreach ($name in @('Manage-AutoFixTask.ps1', 'AutoFix.Common.ps1')) {
        [IO.File]::Copy((Join-Path $root $name), (Join-Path $fixture $name))
    }
    Run-Manager -Mode 'Install' -Source $fixture -Expected 1
    $afterFailure = Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\'
    Check ($afterFailure.Actions[0].WorkingDirectory -eq $current.Actions[0].WorkingDirectory) 'failed copy restores previous safe task'
    Check ($afterFailure.State -eq 'Running') 'previous watcher restarted after failed install'
    Check ((Get-FileHash -LiteralPath $script:MonitorSettingsPath).Hash -eq $settingsHash) 'failed update restores previous monitor settings'
    $watchers = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine.Contains($current.Actions[0].WorkingDirectory) -and $_.CommandLine -like '* -Watch*'
    })
    Check ($watchers.Count -eq 1) 'single watcher process'
    $watcher = [Diagnostics.Process]::GetProcessById($watchers[0].ProcessId)
    Start-Sleep -Seconds 3
    $watcher.Refresh()
    $cpuBefore = $watcher.TotalProcessorTime.TotalSeconds
    Start-Sleep -Seconds 10
    $watcher.Refresh()
    $cpuDelta = $watcher.TotalProcessorTime.TotalSeconds - $cpuBefore
    $reportLines.Add(('INFO: idle sample 10s; CPU seconds={0:F3}; private memory MiB={1:F1}' -f $cpuDelta, ($watcher.PrivateMemorySize64 / 1MB)))
    $watcher.Dispose()
    Check ((Get-FileHash -LiteralPath $script:HostsPath).Hash -eq $hostHash) 'system hosts unchanged'
    $nativeTests = Join-Path $root 'tests\CoreTests\bin\Debug\net8.0-windows\win-x64\CoreTests.exe'
    & $nativeTests --files | ForEach-Object { $reportLines.Add([string]$_) }
    Check ($LASTEXITCODE -eq 0) 'native hosts fixture tests'
    $exitCode = 0
}
catch { $reportLines.Add($_.Exception.Message) }
finally {
    if ($fixture) {
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fixture)) -ne $PSScriptRoot -or [IO.Path]::GetFileName($fixture) -notmatch '^\.fixtures_[a-f0-9]{32} space & bang!$') {
            throw 'Unsafe test cleanup path.'
        }
        foreach ($name in @('Manage-AutoFixTask.ps1', 'AutoFix.Common.ps1')) { [IO.File]::Delete((Join-Path $fixture $name)) }
        [IO.Directory]::Delete($fixture)
    }
    $report = Join-Path $script:DataRoot 'Security-test-results.txt'
    Assert-ProtectedPath $script:DataRoot
    if (Test-Path -LiteralPath $report) { Assert-ProtectedPath $report }
    [IO.File]::WriteAllLines($report, $reportLines, (New-Object Text.UTF8Encoding($false)))
}
exit $exitCode
