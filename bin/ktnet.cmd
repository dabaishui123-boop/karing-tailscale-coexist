@echo off
setlocal
set "SCRIPT=%~dp0ktnet.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
