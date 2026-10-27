@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0subir.ps1" -Modelo flux2 %*
pause
