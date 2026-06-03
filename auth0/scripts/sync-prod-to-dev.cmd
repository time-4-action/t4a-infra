@echo off
REM Double-click wrapper for sync-prod-to-dev.ps1 (pull: prod -> dev).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-prod-to-dev.ps1" %*
