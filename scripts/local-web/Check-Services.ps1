[CmdletBinding()]
param([string]$ProjectRoot)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Get-LocalWebProjectRoot -ScriptsRoot $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

if (-not (Test-IsAdministrator)) {
    throw 'Для запуска и перезапуска служб открой PowerShell от имени администратора.'
}

$logsDirectory = Join-Path $ProjectRoot 'logs'
$logPath = Join-Path $logsDirectory 'service-check.log'
New-Item -ItemType Directory -Path $logsDirectory -Force | Out-Null

function Write-CheckResult {
    param([string]$Level, [string]$Message)
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Invoke-ServiceHealthCheck {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)]$Settings
    )

    $service = Resolve-WindowsService -ServiceName ([string]$Settings.ServiceName) -FriendlyName $Label
    if (-not $service) {
        Write-CheckResult 'ERROR' "$Label`: служба '$($Settings.ServiceName)' не найдена."
        return $false
    }

    $service.Refresh()
    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
        Write-CheckResult 'WARN' "$Label`: служба не запущена (состояние: $($service.Status)); пытаюсь запустить."
        try {
            if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::StartPending) {
                [void](Wait-ServiceRunning -ServiceName $service.Name -TimeoutSeconds 30)
            }
            else {
                if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::StopPending) {
                    $service.WaitForStatus(
                        [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                        [TimeSpan]::FromSeconds(30)
                    )
                }
                Start-Service -Name $service.Name
                [void](Wait-ServiceRunning -ServiceName $service.Name -TimeoutSeconds 30)
            }
        }
        catch {
            Write-CheckResult 'ERROR' "$Label`: не удалось запустить службу: $($_.Exception.Message)"
            return $false
        }
    }

    $url = [string]$Settings.HealthUrl
    $health = Wait-HttpEndpoint -Url $url -Attempts 5 -DelaySeconds 2
    if ($health.Success) {
        Write-CheckResult 'OK' "$Label`: работает; HTTP $($health.StatusCode), $url"
        return $true
    }

    Write-CheckResult 'WARN' "$Label`: служба запущена, но HTTP не отвечает ($url). Перезапускаю службу."
    try {
        Restart-Service -Name $service.Name -Force
        [void](Wait-ServiceRunning -ServiceName $service.Name -TimeoutSeconds 30)
    }
    catch {
        Write-CheckResult 'ERROR' "$Label`: перезапуск не удался: $($_.Exception.Message)"
        return $false
    }

    $health = Wait-HttpEndpoint -Url $url -Attempts 10 -DelaySeconds 2
    if ($health.Success) {
        Write-CheckResult 'OK' "$Label`: восстановлена; HTTP $($health.StatusCode), $url"
        return $true
    }

    Write-CheckResult 'ERROR' "$Label`: не отвечает после перезапуска. Последняя ошибка: $($health.Error)"
    return $false
}

$config = Get-ServiceSettings -ProjectRoot $ProjectRoot
Write-CheckResult 'INFO' 'Начинаю однократную проверку Navidrome и Caddy.'

$navidromeOk = Invoke-ServiceHealthCheck -Label 'Navidrome' -Settings $config.Navidrome
$caddyOk = Invoke-ServiceHealthCheck -Label 'Caddy' -Settings $config.Caddy

if ($navidromeOk -and $caddyOk) {
    Write-CheckResult 'OK' 'Проверка завершена: оба сервиса доступны.'
}
else {
    Write-CheckResult 'ERROR' 'Проверка завершена: один или оба сервиса недоступны. Подробности находятся в logs\service-check.log.'
}
