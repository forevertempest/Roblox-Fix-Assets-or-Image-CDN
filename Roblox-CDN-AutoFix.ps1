# Автоматически подбирает рабочий адрес Roblox CDN и при необходимости обновляет hosts.
# Скрипт рассчитан на Windows PowerShell 5.1 и Windows 10/11.

[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$Domain = "tr.rbxcdn.com"
$HostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$WorkDir = Join-Path $env:ProgramData "RobloxCDNAutoFix"
$BackupDir = Join-Path $WorkDir "backups"
$LogPath = Join-Path $WorkDir "RobloxCDNAutoFix.log"
$OriginalMappingPath = Join-Path $WorkDir "original-domain-mappings.txt"

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
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    catch {
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-BeforeExit {
    if (-not $Quiet) {
        Read-Host "Нажми Enter для выхода" | Out-Null
    }
}

function Restart-AsAdministrator {
    if (Test-IsAdministrator) {
        return
    }

    Write-Host "Запрашиваю права администратора..." -ForegroundColor Yellow

    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath

    if ($Quiet) {
        $arguments += " -Quiet"
    }

    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arguments
    }
    catch {
        Write-Host "Не удалось получить права администратора." -ForegroundColor Red
        Write-Host $_.Exception.Message
        Wait-BeforeExit
    }

    exit
}

function Test-IPv4 {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $parsed = $null

    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsed)) {
        return $false
    }

    return ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
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

    return $result
}

function Invoke-DoHRequest {
    param(
        [string]$ResolverHost,
        [string]$ResolverIP,
        [string]$Url,
        [switch]$Cloudflare
    )

    $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue

    if ($null -eq $curl) {
        return $null
    }

    $curlArgs = @(
        "--silent",
        "--show-error",
        "--fail",
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
        $raw = & curl.exe @curlArgs 2>$null

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

    return $result
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

    return $result
}

function Test-CdnIP {
    param([string]$IP)

    if (-not (Test-IPv4 $IP)) {
        return $false
    }

    $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue

    if ($null -eq $curl) {
        Write-Log "curl.exe не найден." "ERROR"
        return $false
    }

    $curlArgs = @(
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
        $output = & curl.exe @curlArgs 2>$null
        $code = ($output | Select-Object -Last 1)

        if ($null -ne $code) {
            $code = $code.ToString().Trim()
        }

        $ok = (
            ($LASTEXITCODE -eq 0) -and
            ($code -match "^[0-9]{3}$") -and
            ($code -ne "000")
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

function Backup-HostsFile {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPath = Join-Path $BackupDir ("hosts_{0}.bak" -f $stamp)

    Copy-Item -LiteralPath $HostsPath -Destination $backupPath -Force
    Write-Log ("Создана резервная копия hosts: {0}" -f $backupPath)

    return $backupPath
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

        if (($hosts -contains $Domain) -and ($result -notcontains ("{0}`t{1}" -f $ip, $Domain))) {
            $result += ("{0}`t{1}" -f $ip, $Domain)
        }
    }

    return $result
}

function Save-OriginalDomainMappings {
    param([string[]]$CurrentLines)

    if (Test-Path -LiteralPath $OriginalMappingPath) {
        return
    }

    $sourceLines = $CurrentLines
    $hasManagedEntry = $null -ne ($CurrentLines | Where-Object { $_ -match "^\s*#\s*RobloxCDNAutoFix\b" } | Select-Object -First 1)

    if ($hasManagedEntry) {
        $cleanBackup = Get-ChildItem -LiteralPath $BackupDir -Filter "hosts_*.bak" -File -ErrorAction SilentlyContinue |
            Sort-Object Name |
            Where-Object {
                $backupLines = [System.IO.File]::ReadAllLines($_.FullName)
                $null -eq ($backupLines | Where-Object { $_ -match "^\s*#\s*RobloxCDNAutoFix\b" } | Select-Object -First 1)
            } |
            Select-Object -First 1

        if ($null -ne $cleanBackup) {
            $sourceLines = [System.IO.File]::ReadAllLines($cleanBackup.FullName)
        }
        else {
            $sourceLines = @()
        }
    }

    $originalMappings = @(Get-DomainMappingLines -Lines $sourceLines)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($OriginalMappingPath, $originalMappings, $utf8NoBom)
}

function Restore-HostsFile {
    param([string]$BackupPath)

    if ([string]::IsNullOrWhiteSpace($BackupPath) -or (-not (Test-Path -LiteralPath $BackupPath))) {
        throw "Резервная копия hosts не найдена."
    }

    Copy-Item -LiteralPath $BackupPath -Destination $HostsPath -Force
    & ipconfig.exe /flushdns | Out-Null

    Write-Log ("Исходный hosts восстановлен из резервной копии: {0}" -f $BackupPath) "WARN"
}

function Remove-ManagedDomainLines {
    param([string[]]$Lines)

    $result = @()

    foreach ($line in $Lines) {
        if ($line -match "^\s*#\s*RobloxCDNAutoFix\b") {
            continue
        }

        if ($line -match "^\s*\d{1,3}(\.\d{1,3}){3}\s+.*\btr\.rbxcdn\.com\b") {
            $parts = $line -split "\s+"

            if ($parts.Count -ge 2) {
                $ipPart = $parts[0]
                $remainingHosts = @()

                for ($i = 1; $i -lt $parts.Count; $i++) {
                    if ($parts[$i] -and ($parts[$i] -ine $Domain)) {
                        $remainingHosts += $parts[$i]
                    }
                }

                if ($remainingHosts.Count -gt 0) {
                    $result += ($ipPart + "`t" + ($remainingHosts -join " "))
                }

                continue
            }
        }

        $result += $line
    }

    return $result
}

function Set-HostsMapping {
    param([string]$IP)

    if (-not (Test-IPv4 $IP)) {
        throw "Некорректный IPv4."
    }

    $backupPath = Backup-HostsFile

    try {
        $lines = [System.IO.File]::ReadAllLines($HostsPath)
        Save-OriginalDomainMappings -CurrentLines $lines
        $lines = Remove-ManagedDomainLines -Lines $lines

        $newLines = @()

        foreach ($line in $lines) {
            $newLines += $line
        }

        if (($newLines.Count -gt 0) -and (-not [string]::IsNullOrWhiteSpace($newLines[$newLines.Count - 1]))) {
            $newLines += ""
        }

        $newLines += ("# RobloxCDNAutoFix - запись добавлена скриптом - {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
        $newLines += ("{0}`t{1}" -f $IP, $Domain)

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($HostsPath, $newLines, $utf8NoBom)

        Write-Log ("hosts обновлён: {0} -> {1}" -f $Domain, $IP)

        & ipconfig.exe /flushdns | Out-Null
        Write-Log "DNS-кэш Windows очищен."
    }
    catch {
        $updateError = $_

        try {
            Restore-HostsFile -BackupPath $backupPath
        }
        catch {
            Write-Log ("Не удалось автоматически восстановить hosts: {0}" -f $_.Exception.Message) "ERROR"
        }

        throw $updateError
    }

    return $backupPath
}

function Test-HostsMapping {
    param([string]$ExpectedIP)

    $curlArgs = @(
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
        $output = (& curl.exe @curlArgs 2>$null) -join "`n"
        $parts = $output.Trim() -split "\|", 2

        if (($LASTEXITCODE -ne 0) -or ($parts.Count -ne 2)) {
            return $false
        }

        $code = $parts[0]
        $actualIP = $parts[1]
        $ok = (
            ($code -match "^[0-9]{3}$") -and
            ($code -ne "000") -and
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

# Основной сценарий

Restart-AsAdministrator

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

Write-Host "=== Roblox CDN AutoFix ===" -ForegroundColor Cyan
Write-Log ("Запуск диагностики для {0}" -f $Domain)

if (-not (Test-Path -LiteralPath $HostsPath)) {
    Write-Log ("hosts не найден: {0}" -f $HostsPath) "ERROR"
    Show-Result -IP $null -Changed $false
    Wait-BeforeExit
    exit 1
}

if ($null -eq (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    Write-Log "curl.exe не найден. Без него безопасная HTTPS-проверка невозможна." "ERROR"
    Show-Result -IP $null -Changed $false
    Wait-BeforeExit
    exit 1
}

# Сначала проверяем адреса, которые сейчас возвращает Windows.
$currentIPs = @(Get-SystemIPv4)

if ($currentIPs.Count -gt 0) {
    Write-Log ("Текущие IPv4: {0}" -f ($currentIPs -join ", "))

    $workingCurrentIP = Find-WorkingIP -Candidates $currentIPs

    if (-not [string]::IsNullOrWhiteSpace($workingCurrentIP)) {
        Write-Log "CDN уже доступен. Исправление не требуется."
        Show-Result -IP $workingCurrentIP -Changed $false
        Wait-BeforeExit
        exit 0
    }
}
else {
    Write-Log "Текущий DNS не возвращает IPv4 для CDN." "WARN"
}

# Если системный DNS не помог, опрашиваем независимые DoH-серверы.
$googleIPs = @(Get-GoogleDoHIPv4)

if ($googleIPs.Count -gt 0) {
    Write-Log ("Google DoH: {0}" -f ($googleIPs -join ", "))
}
else {
    Write-Log "Google DoH не вернул A-записи." "WARN"
}

$cloudflareIPs = @(Get-CloudflareDoHIPv4)

if ($cloudflareIPs.Count -gt 0) {
    Write-Log ("Cloudflare DoH: {0}" -f ($cloudflareIPs -join ", "))
}
else {
    Write-Log "Cloudflare DoH не вернул A-записи." "WARN"
}

# Сначала перебираем найденные адреса, затем запасной список.
$candidates = @()
$candidates += $googleIPs
$candidates += $cloudflareIPs
$candidates += $FallbackIPs

$workingIP = Find-WorkingIP -Candidates $candidates

if ([string]::IsNullOrWhiteSpace($workingIP)) {
    Write-Log "Рабочий IP не найден. hosts оставлен без изменений." "ERROR"
    Show-Result -IP $null -Changed $false
    Wait-BeforeExit
    exit 2
}

# Записываем только тот адрес, который уже прошёл HTTPS-проверку.
$backupPath = $null

try {
    $backupPath = Set-HostsMapping -IP $workingIP
}
catch {
    Write-Log ("Не удалось обновить hosts: {0}" -f $_.Exception.Message) "ERROR"
    Show-Result -IP $null -Changed $false
    Wait-BeforeExit
    exit 3
}

# После обновления проверяем, что curl действительно использует запись из hosts.
Start-Sleep -Milliseconds 500

if (Test-HostsMapping -ExpectedIP $workingIP) {
    Write-Log "Финальная проверка успешна."
    Show-Result -IP $workingIP -Changed $true
    Wait-BeforeExit
    exit 0
}

Write-Log "Финальная проверка после изменения hosts не прошла." "ERROR"
$hostsRestored = $false

try {
    Restore-HostsFile -BackupPath $backupPath
    $hostsRestored = $true
}
catch {
    Write-Log ("Не удалось откатить изменение hosts: {0}" -f $_.Exception.Message) "ERROR"
}

Show-Result -IP $null -Changed (-not $hostsRestored)
Wait-BeforeExit
exit 4
