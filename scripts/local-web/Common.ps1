# Общие функции для локальной веб-сборки Feishin и служб Windows.

function Get-LocalWebProjectRoot {
    param([Parameter(Mandatory)][string]$ScriptsRoot)
    return [System.IO.Path]::GetFullPath((Join-Path $ScriptsRoot '..\..'))
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-ServiceSettings {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $settings = [pscustomobject]@{
        Navidrome = [pscustomobject]@{
            ServiceName = 'Navidrome'
            HealthUrl   = 'http://127.0.0.1:4533/ping'
        }
        Caddy = [pscustomobject]@{
            ServiceName = 'CaddyFeishin'
            HealthUrl   = 'http://127.0.0.1:9181/'
        }
    }

    $path = Join-Path $ProjectRoot 'services.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $custom = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($name in @('Navidrome', 'Caddy')) {
                if ($custom.$name) {
                    foreach ($property in @('ServiceName', 'HealthUrl')) {
                        $value = [string]$custom.$name.$property
                        if (-not [string]::IsNullOrWhiteSpace($value)) {
                            $target = $settings.$name
                            $target | Add-Member -NotePropertyName $property -NotePropertyValue $value -Force
                        }
                    }
                }
            }
        }
        catch {
            throw "Не удалось прочитать $path : $($_.Exception.Message)"
        }
    }

    return $settings
}

function Resolve-WindowsService {
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [string]$FriendlyName = ''
    )

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) { return $service }

    if (-not [string]::IsNullOrWhiteSpace($FriendlyName)) {
        $matches = @(Get-Service | Where-Object {
            $_.Name -like "*$FriendlyName*" -or $_.DisplayName -like "*$FriendlyName*"
        })
        if ($matches.Count -eq 1) { return $matches[0] }
    }

    return $null
}

function Test-HttpEndpoint {
    param([Parameter(Mandatory)][string]$Url)

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 5 -ErrorAction Stop
        return [pscustomobject]@{
            Success    = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
            StatusCode = [int]$response.StatusCode
            Error      = ''
        }
    }
    catch {
        $statusCode = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        }
        return [pscustomobject]@{
            Success    = $false
            StatusCode = $statusCode
            Error      = $_.Exception.Message
        }
    }
}

function Wait-HttpEndpoint {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$Attempts = 10,
        [int]$DelaySeconds = 2
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        $result = Test-HttpEndpoint -Url $Url
        if ($result.Success) { return $result }
        if ($i -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
    }

    return $result
}

function Wait-ServiceRunning {
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [int]$TimeoutSeconds = 30
    )

    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    $service.WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Running,
        [TimeSpan]::FromSeconds($TimeoutSeconds)
    )
    $service.Refresh()
    return ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)
}

function Get-CaddyExecutable {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $candidates = @(
        (Join-Path $ProjectRoot 'tools\caddy\caddy.exe'),
        (Join-Path $ProjectRoot 'caddy.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    throw "Не найден caddy.exe. Положи его в '$ProjectRoot\tools\caddy\caddy.exe' (предпочтительно) или в корень проекта."
}
