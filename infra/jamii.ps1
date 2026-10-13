<#
.SYNOPSIS
  OPTIONAL shortcuts for the Jamii docker setup. Run from the infra folder.
  Everything here is plain `docker compose` underneath - the commands it runs are printed.

.EXAMPLE
  .\jamii.ps1 up dev            # = docker compose --env-file env/dev.env up -d --build
  .\jamii.ps1 status dev        # containers + health
  .\jamii.ps1 logs dev mi       # follow MI logs (Ctrl+C to stop)
  .\jamii.ps1 rebuild-car dev   # rebuild the .car from source and hot-deploy it to MI
  .\jamii.ps1 reset-db dev      # rebuild Jamii_db from schema.sql + seed.sql
  .\jamii.ps1 down dev          # stop (data volumes are kept)
  .\jamii.ps1 up uat -Force     # uat/prod are placeholders; -Force to really start them
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
    # also pick up local secrets (.env) - an explicit --env-file disables the automatic .env loading
    if (Test-Path (Join-Path $InfraDir '.env')) { $all += @('--env-file', '.env') }
    $all += $Arguments
    Write-Host "> docker $($all -join ' ')" -ForegroundColor DarkGray
    Push-Location $InfraDir
    # docker writes progress to stderr; in PowerShell 5.1 that must not count as a failure,
    # so rely on the exit code only.
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
        # MI notices the replaced .car in its carbonapps volume and redeploys it (~15s)
        Invoke-Compose @('run', '--rm', '-e', 'FORCE_CAR_BUILD=true', 'car-build')
        Write-Host "Done. Watch the redeploy with: .\jamii.ps1 logs $EnvName mi" -ForegroundColor Green
    }
    'reset-db' {
        Invoke-Compose @('run', '--rm', '-e', 'RESET_DB=true', 'sqlite-init')
        Invoke-Compose @('restart', 'mi')
    }
}
