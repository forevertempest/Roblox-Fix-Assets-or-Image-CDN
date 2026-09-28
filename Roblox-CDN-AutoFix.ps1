# Автоматически подбирает рабочий адрес Roblox CDN и при необходимости обновляет hosts.
# Скрипт рассчитан на Windows PowerShell 5.1 и Windows 10/11.

[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$env:PSModulePath = Join-Path $PSHOME 'Modules'
$env:PATH = [Environment]::SystemDirectory
Set-Location -LiteralPath ([Environment]::SystemDirectory)
. (Join-Path $PSScriptRoot 'AutoFix.Common.ps1')
$Domain = "tr.rbxcdn.com"
$WorkDir = $script:DataRoot
$BackupDir = Join-Path $WorkDir 'backups'
$LogPath = Join-Path $WorkDir "RobloxCDNAutoFix.log"

# Эти адреса используем только как запасной вариант.
# Перед записью в hosts каждый адрес обязательно проверяется по HTTPS.
$FallbackIPs = @(
    "3.171.117.54",
    "3.171.117.73",
    "3.164.195.121",
    "18.65.39.105",
    "2.20.245.170",
    "18.64.211.78",
    "18.64.211.88",
    "18.64.211.103",
    "18.64.211.77"
)

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line

    try {
        Write-RotatingLog 'RobloxCDNAutoFix.log' $line
    }
    catch {
    }
}

function Wait-BeforeExit {
    if (-not $Quiet) {
        Read-Host "Нажми Enter для выхода" | Out-Null
    }
}

function Restart-AsAdministrator {
    if (Test-IsAdministrator) { return }
    if ($Quiet) { throw 'Для фонового исправления нужны права администратора.' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    try {
        $process = Start-Process -FilePath $script:PowerShellExe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
        if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath -Encoding UTF8 -Tail 8 }
        Write-Host ("Код завершения: {0}" -f $process.ExitCode)
        Wait-BeforeExit
        exit $process.ExitCode
    }
    catch { Write-Host $_.Exception.Message; Wait-BeforeExit; exit 1 }
}

function Get-SystemIPv4 {
    $result = @()

    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($Domain)

        foreach ($address in $addresses) {
            $ip = $address.ToString()

            if ((Test-IPv4 $ip) -and ($result -notcontains $ip)) {
                $result += $ip
            }
        }
    }
    catch {
        Write-Log ("Обычный DNS не вернул IPv4 для {0}. Ошибка: {1}" -f $Domain, $_.Exception.Message) "WARN"
    }

    return @($result | Select-Object -First 16)
}

function Invoke-DoHRequest {
    param(
        [string]$ResolverHost,
        [string]$ResolverIP,
        [string]$Url,
        [switch]$Cloudflare
    )

    $curl = Get-Item -LiteralPath $script:CurlExe -ErrorAction SilentlyContinue

    if ($null -eq $curl) {
        return $null
    }

    $curlArgs = @(
        "--disable",
        "--proto", "=https",
        "--silent",
        "--show-error",
        "--fail",
        "--max-filesize", "262144",
        "--noproxy", "*",
        "--connect-timeout", "4",
        "--max-time", "8",
        "--resolve", ("{0}:443:{1}" -f $ResolverHost, $ResolverIP)
    )

    if ($Cloudflare) {
        $curlArgs += "-H"
        $curlArgs += "accept: application/dns-json"
    }

    $curlArgs += $Url

    try {
        $raw = & $script:CurlExe @curlArgs 2>$null

        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        $text = $raw -join "`n"

        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        return ($text | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-GoogleDoHIPv4 {
    $result = @()
    $url = "https://dns.google/resolve?name={0}&type=A" -f $Domain

    $json = Invoke-DoHRequest `
        -ResolverHost "dns.google" `
        -ResolverIP "8.8.8.8" `
        -Url $url

    if ($null -eq $json) {
        return $result
    }

    if ($null -eq $json.Answer) {
        return $result
    }

    foreach ($answer in $json.Answer) {
        if ($answer.type -eq 1) {
            $ip = [string]$answer.data

            if ((Test-IPv4 $ip) -and ($result -notcontains $ip)) {
                $result += $ip
            }
        }
    }

    return @($result | Select-Object -First 16)
}

function Get-CloudflareDoHIPv4 {
    $result = @()
    $url = "https://cloudflare-dns.com/dns-query?name={0}&type=A" -f $Domain

    $json = Invoke-DoHRequest `
        -ResolverHost "cloudflare-dns.com" `
        -ResolverIP "1.1.1.1" `
        -Url $url `
        -Cloudflare

    if ($null -eq $json) {
        return $result
    }

    if ($null -eq $json.Answer) {
        return $result
    }

    foreach ($answer in $json.Answer) {
        if ($answer.type -eq 1) {
            $ip = [string]$answer.data

            if ((Test-IPv4 $ip) -and ($result -notcontains $ip)) {
                $result += $ip
            }
        }
    }

    return @($result | Select-Object -First 16)
}

function Test-CdnIP {
    param([string]$IP)

    if (-not (Test-IPv4 $IP)) {
        return $false
    }

    $curl = Get-Item -LiteralPath $script:CurlExe -ErrorAction SilentlyContinue

    if ($null -eq $curl) {
        Write-Log "curl.exe не найден." "ERROR"
        return $false
    }

    $curlArgs = @(
        "--disable",
        "--proto", "=https",
        "--silent",
        "--show-error",
        "--output", "NUL",
        "--write-out", "%{http_code}",
        "--noproxy", "*",
        "--ipv4",
        "--connect-timeout", "4",
        "--max-time", "8",
        "--resolve", ("{0}:443:{1}" -f $Domain, $IP),
        ("https://{0}/" -f $Domain)
    )

    try {
        $output = & $script:CurlExe @curlArgs 2>$null
        $code = ($output | Select-Object -Last 1)

        if ($null -ne $code) {
            $code = $code.ToString().Trim()
        }

        $ok = (
            ($LASTEXITCODE -eq 0) -and
            ($code -match "^[1-5][0-9]{2}$")
        )

        if ($ok) {
            Write-Log ("Проверка {0}: HTTPS работает, HTTP {1}." -f $IP, $code)
            return $true
        }

        Write-Log ("Проверка {0}: не прошла." -f $IP) "WARN"
        return $false
    }
    catch {
        Write-Log ("Проверка {0}: ошибка {1}" -f $IP, $_.Exception.Message) "WARN"
        return $false
    }
}

function Find-WorkingIP {
    param([string[]]$Candidates)

    $checked = @()

    foreach ($ip in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($ip)) {
            continue
        }

        if ($checked -contains $ip) {
            continue
        }

        $checked += $ip
        Write-Log ("Тестирую CDN IP: {0}" -f $ip)

        if (Test-CdnIP $ip) {
            return $ip
        }
    }

    return $null
}

function Set-HostsMapping {
    param([string]$IP)
    if (-not (Test-IPv4 $IP)) { throw 'Некорректный IPv4.' }
    $snapshot = Read-HostsSnapshot
    $clean = Get-UnmanagedHostsText $snapshot.Text
    if (Test-ForeignMapping $clean) {
        throw 'В hosts есть чужая запись tr.rbxcdn.com. Она сохранена; автоматическая замена запрещена.'
    }
    $newline = [Environment]::NewLine
    if ($clean.Length -gt 0 -and -not $clean.EndsWith($newline)) { $clean += $newline }
    $newText = $clean + '# RobloxCDNAutoFix BEGIN' + $newline + $IP + "`t" + $Domain + $newline + '# RobloxCDNAutoFix END' + $newline
    $transaction = Write-HostsTransaction $snapshot $newText
    Write-Log ("Создана резервная копия: {0}" -f $transaction.Backup)
    try { Clear-AutoFixDns }
    catch { Set-HostsBytes $transaction.Before $transaction.AfterHash; throw }
    return $transaction
}

function Test-HostsMapping {
    param([string]$ExpectedIP)

    $curlArgs = @(
        "--disable",
        "--proto", "=https",
        "--silent",
        "--show-error",
        "--output", "NUL",
        "--write-out", "%{http_code}|%{remote_ip}",
        "--noproxy", "*",
        "--ipv4",
        "--connect-timeout", "4",
        "--max-time", "8",
        ("https://{0}/" -f $Domain)
    )

    try {
        $output = (& $script:CurlExe @curlArgs 2>$null) -join "`n"
        $parts = $output.Trim() -split "\|", 2

        if (($LASTEXITCODE -ne 0) -or ($parts.Count -ne 2)) {
            return $false
        }

        $code = $parts[0]
        $actualIP = $parts[1]
        $ok = (
            ($code -match "^[1-5][0-9]{2}$") -and
            ($actualIP -eq $ExpectedIP)
        )

        if ($ok) {
            Write-Log ("hosts работает: {0} открывается через {1}, HTTP {2}." -f $Domain, $actualIP, $code)
            return $true
        }

        Write-Log ("Проверка hosts не прошла: ожидался {0}, получен {1}, HTTP {2}." -f $ExpectedIP, $actualIP, $code) "WARN"
        return $false
    }
    catch {
        Write-Log ("Не удалось проверить запись в hosts: {0}" -f $_.Exception.Message) "WARN"
        return $false
    }
}

function Show-Result {
    param(
        [string]$IP,
        [bool]$Changed
    )

    Write-Host ""

    if (-not [string]::IsNullOrWhiteSpace($IP)) {
        Write-Host "ГОТОВО" -ForegroundColor Green
        Write-Host ("Рабочий CDN: {0} -> {1}" -f $Domain, $IP)

        if ($Changed) {
            Write-Host "hosts обновлён. Если Roblox был открыт, полностью перезапусти его."
        }
        else {
            Write-Host "CDN уже работает. Ничего менять не пришлось."
        }

        return
    }

    Write-Host "РАБОЧИЙ IP НЕ НАЙДЕН" -ForegroundColor Red

    if ($Changed) {
        Write-Host "Не удалось автоматически откатить изменение hosts. Подробности есть в логе."
    }
    else {
        Write-Host "hosts оставлен без изменений или восстановлен из резервной копии."
    }

    Write-Host ("Лог: {0}" -f $LogPath)
}

# Блокировка удерживается до завершения проверки и возможного отката.
Restart-AsAdministrator
$operationLock = $null
$exitCode = 1
try {
    Initialize-AutoFixData
    $operationLock = Enter-AutoFixLock
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') {
        Assert-Release $PSScriptRoot
    }
    Write-Log ("Запуск диагностики для {0}" -f $Domain)
    if (-not (Test-Path -LiteralPath $script:CurlExe)) { throw 'Системный curl.exe не найден.' }
    $currentIPs = @(Get-SystemIPv4)
    $workingCurrentIP = Find-WorkingIP -Candidates $currentIPs
    if (-not [string]::IsNullOrWhiteSpace($workingCurrentIP)) {
        Write-Log 'CDN уже доступен. Изменения не требуются.'
        Show-Result -IP $workingCurrentIP -Changed $false
        $exitCode = 0
    }
    else {
        $candidates = @(Get-GoogleDoHIPv4) + @(Get-CloudflareDoHIPv4) + $FallbackIPs
        $workingIP = Find-WorkingIP -Candidates $candidates
        if ([string]::IsNullOrWhiteSpace($workingIP)) {
            Write-Log 'Рабочий IP не найден. hosts не изменён.' 'ERROR'
            $exitCode = 2
        }
        else {
            $exitCode = 3
            $transaction = Set-HostsMapping $workingIP
            if (Test-HostsMapping $workingIP) {
                Write-Log 'Финальная проверка успешна.'
                Show-Result -IP $workingIP -Changed $true
                $exitCode = 0
            }
            else {
                $exitCode = 4
                Set-HostsBytes $transaction.Before $transaction.AfterHash
                Clear-AutoFixDns
                Write-Log 'Финальная проверка не прошла. hosts восстановлен.' 'ERROR'
            }
        }
    }
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
}
finally {
    if ($null -ne $operationLock) { $operationLock.Dispose() }
}
if (-not $Quiet -and -not (Test-IsAdministrator)) { Wait-BeforeExit }
exit $exitCode
