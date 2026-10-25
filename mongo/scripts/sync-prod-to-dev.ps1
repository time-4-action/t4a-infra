#requires -Version 5
<#
.SYNOPSIS
    Copy MongoDB data: prod -> dev.

.DESCRIPTION
    Dumps EVERY database from PROD and restores them into DEV, making dev a
    fresh copy of prod. Any database name in the connection-string path is
    stripped first, so the whole instance is mirrored (not just one db).
    dev is treated as a scratch copy and is OVERWRITTEN (--drop): every
    collection present in the prod dump is dropped in dev before restore.

    MongoDB auth and cluster internals are NOT touched. By default the
    excluded namespaces (mongorestore --nsExclude) are:
      admin.system.*  - login users, passwords, roles, keys (auth)
      config.*        - cluster/sharding/session metadata
      local.*         - replica-set / oplog state
    Excluded namespaces are never carried over and never dropped in dev, so
    dev keeps its own credentials and replica-set identity. Real data dbs
    (e.g. t4a, patrik) are cloned in full. Override with -ExcludeNs.

    Connection strings are read from the environment as PROD_MONGOSH and
    DEV_MONGOSH. Run this through the npm script so dotenvx injects them
    from the encrypted mongo/.env:

        npm run mongo:sync:prod-to-dev

    Requires the MongoDB Database Tools (mongodump / mongorestore) on PATH.
    These are separate from mongosh: https://www.mongodb.com/docs/database-tools/

.PARAMETER Force
    Skip the confirmation prompt. Use only in automation you trust.

.PARAMETER ExcludeNs
    Namespace patterns to skip on restore (mongorestore --nsExclude).
    Defaults to admin.system.* so MongoDB auth users/creds are preserved.

.EXAMPLE
    npm run mongo:sync:prod-to-dev
.EXAMPLE
    dotenvx run -f mongo/.env -- pwsh mongo/scripts/sync-prod-to-dev.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string[]]$ExcludeNs = @('admin.system.*', 'config.*', 'local.*')
)

$ErrorActionPreference = 'Stop'

function Get-HostHint {
    # Pull just the host out of a connection URI, for safe display (no creds).
    param([string]$Uri)
    if ($Uri -match '@([^/?]+)') { return $Matches[1] }
    return '(unparsed host)'
}

function ConvertTo-InstanceUri {
    # Drop the path database (e.g. /admin) so mongodump/mongorestore act on the
    # whole instance instead of a single db. Auth is preserved by pinning
    # authSource to the original path db (or admin) when not already set.
    param([string]$Uri)
    if ($Uri -notmatch '^(?<pre>mongodb(?:\+srv)?://[^/]+)(?:/(?<db>[^/?]+))?(?<query>\?.*)?$') {
        return $Uri  # unrecognised shape - leave untouched
    }
    $pre   = $Matches['pre']
    $db    = $Matches['db']
    $query = $Matches['query']

    if ($query) {
        if ($query -notmatch '(?i)authSource=') {
            $authSrc = if ($db) { $db } else { 'admin' }
            $query = "$query&authSource=$authSrc"
        }
    }
    else {
        $authSrc = if ($db) { $db } else { 'admin' }
        $query = "?authSource=$authSrc"
    }
    return "$pre/$query"
}

$Prod = $env:PROD_MONGOSH
$Dev  = $env:DEV_MONGOSH

if ([string]::IsNullOrWhiteSpace($Prod) -or [string]::IsNullOrWhiteSpace($Dev)) {
    throw "PROD_MONGOSH / DEV_MONGOSH not set. Run via: npm run mongo:sync:prod-to-dev"
}

# A db in the URI path (e.g. /admin) would scope the dump to that one db.
# Rewrite to whole-instance URIs so every database is mirrored.
$Prod = ConvertTo-InstanceUri $Prod
$Dev  = ConvertTo-InstanceUri $Dev
if ($Prod -eq $Dev) {
    throw "PROD_MONGOSH and DEV_MONGOSH are identical - refusing to copy a database onto itself."
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
if ($ExcludeNs.Count -gt 0) {
    Write-Host "  PRESERVED (not dumped, not dropped): $($ExcludeNs -join ', ')" -ForegroundColor Green
}
Write-Host ''

if (-not $Force) {
    $answer = Read-Host "Type 'dev' to confirm overwriting the dev database (Ctrl+C to abort)"
    if ($answer -ne 'dev') { throw 'Aborted - confirmation did not match.' }
}

$archive = Join-Path ([System.IO.Path]::GetTempPath()) "t4a-mongo-sync-$PID.archive.gz"
try {
    Write-Host '==> Dumping PROD ...' -ForegroundColor Cyan
    & mongodump --uri="$Prod" --archive="$archive" --gzip
    if ($LASTEXITCODE -ne 0) { throw "mongodump failed (exit $LASTEXITCODE)" }

    # --nsExclude keeps the auth namespaces from being restored. With --drop,
    # mongorestore only drops collections it actually restores, so excluded
    # namespaces are neither dropped nor overwritten in dev.
    $restoreArgs = @("--uri=$Dev", "--archive=$archive", '--gzip', '--drop')
    foreach ($ns in $ExcludeNs) { $restoreArgs += "--nsExclude=$ns" }

    Write-Host '==> Restoring into DEV (--drop) ...' -ForegroundColor Cyan
    & mongorestore @restoreArgs
    if ($LASTEXITCODE -ne 0) { throw "mongorestore failed (exit $LASTEXITCODE)" }

    Write-Host '==> Done. dev now mirrors prod.' -ForegroundColor Green
}
finally {
    if (Test-Path $archive) { Remove-Item $archive -Force }
}
