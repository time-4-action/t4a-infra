@echo off
REM Double-click wrapper for the MongoDB prod -> dev pull.
REM Runs through npm so dotenvx injects PROD_MONGOSH / DEV_MONGOSH from mongo/.env.
pushd "%~dp0..\.."
call npm run mongo:sync:prod-to-dev %*
popd
