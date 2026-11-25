[CmdletBinding()]
param([string]$ProjectRoot)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Common.ps1')

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Get-LocalWebProjectRoot -ScriptsRoot $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
Set-Location -LiteralPath $ProjectRoot

$packagePath = Join-Path $ProjectRoot 'package.json'
$lockPath = Join-Path $ProjectRoot 'pnpm-lock.yaml'
$templatePath = Join-Path $ProjectRoot 'settings.js.template'
if (-not (Test-Path -LiteralPath $packagePath) -or -not (Test-Path -LiteralPath $lockPath)) {
    throw "В '$ProjectRoot' не найдены package.json и pnpm-lock.yaml."
}
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Не найден шаблон настроек: $templatePath"
}

$package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
if ([string]$package.packageManager -notmatch '^pnpm@(.+)$') {
    throw "Не удалось определить версию pnpm из package.json: '$($package.packageManager)'"
}
$requiredPnpm = $Matches[1]

$pnpmCommand = Get-Command pnpm -ErrorAction SilentlyContinue
if (-not $pnpmCommand) {
    throw 'pnpm не найден. Установи pnpm или включи Corepack, затем повтори запуск.'
}
$pnpmRunner = $pnpmCommand.Source
$pnpmPrefix = @()
$installedPnpm = (& $pnpmRunner --version).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Не удалось определить версию pnpm.' }

if ($installedPnpm -ne $requiredPnpm) {
    $corepack = Get-Command corepack -ErrorAction SilentlyContinue
    if (-not $corepack) {
        throw "Проект ожидает pnpm $requiredPnpm, установлен pnpm $installedPnpm. Установи нужную версию или настрой Corepack."
    }
    $pnpmRunner = $corepack.Source
    $pnpmPrefix = @('pnpm')
    $installedPnpm = (& $pnpmRunner @pnpmPrefix --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $installedPnpm -ne $requiredPnpm) {
        throw "Corepack не запустил требуемый pnpm $requiredPnpm (получено: $installedPnpm)."
    }
}

function Invoke-Pnpm {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $allArguments = @()
    $allArguments += $script:pnpmPrefix
    $allArguments += $Arguments
    & $script:pnpmRunner @allArguments
    if ($LASTEXITCODE -ne 0) {
        throw "pnpm завершился с кодом $LASTEXITCODE : $($Arguments -join ' ')"
    }
}

Write-Host "Проект: $ProjectRoot" -ForegroundColor Cyan
Write-Host "pnpm: $installedPnpm" -ForegroundColor DarkGray
Write-Host ''
Write-Host '1/3 Устанавливаю зависимости без install lifecycle-скриптов...' -ForegroundColor Cyan
Write-Host 'Это пропускает postinstall Feishin, который скачивает Electron.' -ForegroundColor DarkGray
Invoke-Pnpm @('install', '--frozen-lockfile', '--ignore-scripts')

Write-Host ''
Write-Host '2/3 Собираю только браузерную версию...' -ForegroundColor Cyan
Invoke-Pnpm @('run', 'build:web')

$webDirectory = Join-Path $ProjectRoot 'out\web'
$indexPath = Join-Path $webDirectory 'index.html'
if (-not (Test-Path -LiteralPath $indexPath)) {
    throw "Сборка завершилась, но не найден '$indexPath'."
}

Write-Host ''
Write-Host '3/3 Создаю settings.js из шаблона...' -ForegroundColor Cyan
$settingsContent = Get-Content -LiteralPath $templatePath -Raw
$settingsContent = [regex]::Replace($settingsContent, '\$\{([A-Z0-9_]+)\}', [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    if ($match.Groups[1].Value -eq 'ANALYTICS_DISABLED') { return 'true' }
    return ''
})
Write-Utf8NoBom -Path (Join-Path $webDirectory 'settings.js') -Content $settingsContent

Write-Host ''
Write-Host "Готово: $webDirectory" -ForegroundColor Green
Write-Host 'Если Caddy уже запущен, достаточно обновить Feishin в браузере через Ctrl+F5.' -ForegroundColor Gray
