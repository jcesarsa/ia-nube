@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bajar.ps1" %*
pause
