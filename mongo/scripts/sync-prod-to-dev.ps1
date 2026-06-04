#requires -Version 5
<#
.SYNOPSIS
    Copy MongoDB data: prod -> dev.

.DESCRIPTION
    Dumps the PROD database and restores it into DEV, making dev a fresh
    copy of prod. dev is treated as a scratch copy and is OVERWRITTEN
    (--drop): every collection present in the prod dump is dropped in dev
    before the restore.

    Connection strings are read from the environment as PROD_MONGOSH and
    DEV_MONGOSH. Run this through the npm script so dotenvx injects them
    from the encrypted mongo/.env:

        npm run mongo:sync:prod-to-dev

    Requires the MongoDB Database Tools (mongodump / mongorestore) on PATH.
    These are separate from mongosh: https://www.mongodb.com/docs/database-tools/

.PARAMETER Force
    Skip the confirmation prompt. Use only in automation you trust.

.EXAMPLE
    npm run mongo:sync:prod-to-dev
.EXAMPLE
    dotenvx run -f mongo/.env -- pwsh mongo/scripts/sync-prod-to-dev.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-HostHint {
    # Pull just the host out of a connection URI, for safe display (no creds).
    param([string]$Uri)
    if ($Uri -match '@([^/?]+)') { return $Matches[1] }
    return '(unparsed host)'
}

$Prod = $env:PROD_MONGOSH
$Dev  = $env:DEV_MONGOSH

if ([string]::IsNullOrWhiteSpace($Prod) -or [string]::IsNullOrWhiteSpace($Dev)) {
    throw "PROD_MONGOSH / DEV_MONGOSH not set. Run via: npm run mongo:sync:prod-to-dev"
}
if ($Prod -eq $Dev) {
    throw "PROD_MONGOSH and DEV_MONGOSH are identical — refusing to copy a database onto itself."
}
foreach ($tool in 'mongodump', 'mongorestore') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found on PATH. Install the MongoDB Database Tools: https://www.mongodb.com/docs/database-tools/"
    }
}

$prodHost = Get-HostHint $Prod
$devHost  = Get-HostHint $Dev

Write-Host ''
Write-Host 'MongoDB pull: prod -> dev' -ForegroundColor Cyan
Write-Host "  FROM (prod): $prodHost"
Write-Host "  INTO (dev):  $devHost" -ForegroundColor Yellow
Write-Host '  dev collections in the dump will be DROPPED and replaced.' -ForegroundColor Yellow
Write-Host ''

if (-not $Force) {
    $answer = Read-Host "Type 'dev' to confirm overwriting the dev database (Ctrl+C to abort)"
    if ($answer -ne 'dev') { throw 'Aborted — confirmation did not match.' }
}

$archive = Join-Path ([System.IO.Path]::GetTempPath()) "t4a-mongo-sync-$PID.archive.gz"
try {
    Write-Host '==> Dumping PROD ...' -ForegroundColor Cyan
    & mongodump --uri="$Prod" --archive="$archive" --gzip
    if ($LASTEXITCODE -ne 0) { throw "mongodump failed (exit $LASTEXITCODE)" }

    Write-Host '==> Restoring into DEV (--drop) ...' -ForegroundColor Cyan
    & mongorestore --uri="$Dev" --archive="$archive" --gzip --drop
    if ($LASTEXITCODE -ne 0) { throw "mongorestore failed (exit $LASTEXITCODE)" }

    Write-Host '==> Done. dev now mirrors prod.' -ForegroundColor Green
}
finally {
    if (Test-Path $archive) { Remove-Item $archive -Force }
}
