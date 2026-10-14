<#
.SYNOPSIS
  Shortcuts for docker compose, e.g. .\jamii.ps1 up dev | status | logs dev mi | rebuild-car | reset-db | down
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('up', 'down', 'status', 'logs', 'rebuild-car', 'reset-db')]
    [string]$Command,

    [Parameter(Position = 1)]
    [ValidateSet('dev', 'uat', 'prod')]
    [string]$EnvName = 'dev',

    [Parameter(Position = 2)]
    [string]$Service,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$InfraDir = $PSScriptRoot
$EnvFile  = "env/$EnvName.env"

function Invoke-Compose([string[]]$Arguments) {
    $all = @('compose', '--env-file', $EnvFile)
    if (Test-Path (Join-Path $InfraDir '.env')) { $all += @('--env-file', '.env') }
    $all += $Arguments
    Write-Host "> docker $($all -join ' ')" -ForegroundColor DarkGray
    Push-Location $InfraDir
    # docker writes progress to stderr, which PowerShell 5.1 treats as an error
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker @all }
    finally { $ErrorActionPreference = $previous; Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "docker compose failed with exit code $LASTEXITCODE" }
}

switch ($Command) {
    'up' {
        if ($EnvName -ne 'dev' -and -not $Force) {
            throw "'$EnvName' is a placeholder environment (not enough RAM to run it next to dev). Use -Force if you really mean it."
        }
        Invoke-Compose @('up', '-d', '--build')
        Write-Host "`nStarted. APIM takes ~2-3 minutes to become healthy. Check with: .\jamii.ps1 status $EnvName" -ForegroundColor Green
    }
    'down'   { Invoke-Compose @('down') }
    'status' { Invoke-Compose @('ps', '-a') }
    'logs' {
        $logArgs = @('logs', '-f', '--tail', '200')
        if ($Service) { $logArgs += $Service }
        Invoke-Compose $logArgs
    }
    'rebuild-car' {
        Invoke-Compose @('run', '--rm', '-e', 'FORCE_CAR_BUILD=true', 'car-build')
        Write-Host "Done. Watch the redeploy with: .\jamii.ps1 logs $EnvName mi" -ForegroundColor Green
    }
    'reset-db' {
        Invoke-Compose @('run', '--rm', '-e', 'RESET_DB=true', 'sqlite-init')
        Invoke-Compose @('restart', 'mi')
    }
}
