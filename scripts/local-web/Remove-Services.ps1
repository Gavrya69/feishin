[CmdletBinding()]
param([string]$ProjectRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Get-LocalWebProjectRoot -ScriptsRoot $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

if (-not (Test-IsAdministrator)) {
    throw 'Открой PowerShell от имени администратора и повтори запуск.'
}

$config = Get-ServiceSettings -ProjectRoot $ProjectRoot
$serviceName = [string]$config.Caddy.ServiceName
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if (-not $service) {
    Write-Host "Служба $serviceName не установлена." -ForegroundColor Yellow
    return
}

if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
    Write-Host "Останавливаю $serviceName..." -ForegroundColor Cyan
    Stop-Service -Name $serviceName -Force
    (Get-Service -Name $serviceName).WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Stopped,
        [TimeSpan]::FromSeconds(30)
    )
}

& sc.exe delete $serviceName
if ($LASTEXITCODE -ne 0) {
    throw "Не удалось удалить службу $serviceName через sc.exe delete."
}

Write-Host "Служба $serviceName удалена." -ForegroundColor Green
Write-Host 'Navidrome, Caddyfile, caddy.exe и собранные файлы Feishin не затронуты.' -ForegroundColor Gray
