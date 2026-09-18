@echo off
setlocal EnableExtensions
title Discord Auto Login - Backup Session
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Monitor.ps1" -Backup
echo.
pause
