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

$webIndex = Join-Path $ProjectRoot 'out\web\index.html'
$settingsJs = Join-Path $ProjectRoot 'out\web\settings.js'
if (-not (Test-Path -LiteralPath $webIndex) -or -not (Test-Path -LiteralPath $settingsJs)) {
    throw 'Сначала выполни scripts\local-web\Build-Web.ps1.'
}

$caddyExe = Get-CaddyExecutable -ProjectRoot $ProjectRoot
$caddyfile = Join-Path $ProjectRoot 'Caddyfile'
$logsDirectory = Join-Path $ProjectRoot 'logs'
New-Item -ItemType Directory -Path $logsDirectory -Force | Out-Null

if (-not (Test-Path -LiteralPath $caddyfile)) {
    $webRoot = ((Join-Path $ProjectRoot 'out\web') -replace '\\', '/') -replace '"', '\\"'
    $accessLog = ((Join-Path $logsDirectory 'caddy-access.log') -replace '\\', '/') -replace '"', '\\"'
    $content = @"
{
    admin off
}

http://127.0.0.1:9181 {
    root * "$webRoot"
    encode zstd gzip

    @settings path /settings.js
    header @settings Cache-Control "no-store"

    try_files {path} /index.html
    file_server

    log {
        output file "$accessLog" {
            roll_size 5MiB
            roll_keep 3
        }
    }
}
"@
    Write-Utf8NoBom -Path $caddyfile -Content $content
    Write-Host "Создан Caddyfile: $caddyfile" -ForegroundColor Green
}

Write-Host 'Проверяю Caddyfile...' -ForegroundColor Cyan
& $caddyExe validate --config $caddyfile --adapter caddyfile
if ($LASTEXITCODE -ne 0) {
    throw 'Caddyfile не прошёл проверку. Служба не установлена/не изменена.'
}

$servicesConfigPath = Join-Path $ProjectRoot 'services.json'
if (-not (Test-Path -LiteralPath $servicesConfigPath)) {
    $servicesConfig = @'
{
  "Navidrome": {
    "ServiceName": "Navidrome",
    "HealthUrl": "http://127.0.0.1:4533/ping"
  },
  "Caddy": {
    "ServiceName": "CaddyFeishin",
    "HealthUrl": "http://127.0.0.1:9181/"
  }
}
'@
    Write-Utf8NoBom -Path $servicesConfigPath -Content $servicesConfig
}

$config = Get-ServiceSettings -ProjectRoot $ProjectRoot
$navidrome = Resolve-WindowsService -ServiceName $config.Navidrome.ServiceName -FriendlyName 'Navidrome'
if ($navidrome) {
    Set-Service -Name $navidrome.Name -StartupType Automatic
    Write-Host "Автозапуск Navidrome включён: $($navidrome.Name)" -ForegroundColor Green
}
else {
    Write-Warning "Служба Navidrome '$($config.Navidrome.ServiceName)' не найдена. Её имя можно изменить в services.json."
}

$serviceName = [string]$config.Caddy.ServiceName
$binaryPath = '"{0}" run --config "{1}" --adapter caddyfile' -f $caddyExe, $caddyfile
$existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($existing) {
    if ($existing.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $serviceName -Force
        (Get-Service -Name $serviceName).WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(30)
        )
    }
    & sc.exe config $serviceName 'start=' 'auto' 'binPath=' $binaryPath
    if ($LASTEXITCODE -ne 0) { throw "Не удалось обновить службу $serviceName через sc.exe config." }
}
else {
    & sc.exe create $serviceName 'start=' 'auto' 'binPath=' $binaryPath
    if ($LASTEXITCODE -ne 0) { throw "Не удалось создать службу $serviceName через sc.exe create." }
}

& sc.exe description $serviceName 'Local Feishin web interface served by Caddy' | Out-Null
& sc.exe failure $serviceName 'reset=' '86400' 'actions=' 'restart/5000/restart/15000/restart/60000' | Out-Null
& sc.exe failureflag $serviceName '1' | Out-Null

Start-Service -Name $serviceName
if (-not (Wait-ServiceRunning -ServiceName $serviceName -TimeoutSeconds 30)) {
    throw "Служба $serviceName не перешла в состояние Running."
}

$health = Wait-HttpEndpoint -Url ([string]$config.Caddy.HealthUrl) -Attempts 10 -DelaySeconds 2
if ($health.Success) {
    Write-Host "Caddy работает как служба $serviceName." -ForegroundColor Green
    Write-Host "Feishin: $($config.Caddy.HealthUrl)" -ForegroundColor Green
}
else {
    Write-Warning "Служба запущена, но HTTP не отвечает: $($config.Caddy.HealthUrl). Проверь Caddyfile и logs."
}
