#requires -Version 5
<#
.SYNOPSIS
    Pull Auth0 config: prod -> dev.

.DESCRIPTION
    Exports the PROD tenant, pauses so you can template env-specific values
    (URLs / audiences) with ##KEYWORD## placeholders, then imports into DEV.
    dev is treated as a scratch copy of prod.

    Secrets are read from the dotenvx-encrypted auth0/.env.prod and
    auth0/.env.dev via the project's npm scripts. You need the decryption
    keys (auth0/.env.keys, or DOTENV_PRIVATE_KEY_* in the environment).

.PARAMETER Force
    Skip the manual templating pause and import immediately. Use only when
    tenant.yaml already has correct placeholders.

.EXAMPLE
    npm run auth0:sync:prod-to-dev
.EXAMPLE
    pwsh auth0/scripts/sync-prod-to-dev.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Repo root = two levels up from this script (auth0/scripts/ -> repo).
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Push-Location $RepoRoot
try {
    Write-Host '==> Exporting PROD tenant -> auth0/tenant/ ...' -ForegroundColor Cyan
    npm run auth0:export:prod
    if ($LASTEXITCODE -ne 0) { throw "prod export failed (exit $LASTEXITCODE)" }

    if (-not $Force) {
        Write-Host ''
        Write-Host 'Template env-specific values before importing into dev.' -ForegroundColor Yellow
        Write-Host 'Open auth0/tenant/tenant.yaml and replace prod URLs / audiences with'
        Write-Host '  ##PORTAL_URL##   and   ##API_IDENTIFIER##'
        Write-Host 'so dev does not point at prod. See auth0/tenant/README.md.'
        Write-Host ''
        Read-Host 'Press Enter to import into DEV (Ctrl+C to abort)' | Out-Null
    }

    Write-Host '==> Importing into DEV tenant ...' -ForegroundColor Cyan
    npm run auth0:import:dev
    if ($LASTEXITCODE -ne 0) { throw "dev import failed (exit $LASTEXITCODE)" }

    Write-Host '==> Done. dev now mirrors prod (with dev URLs).' -ForegroundColor Green
}
finally {
    Pop-Location
}
