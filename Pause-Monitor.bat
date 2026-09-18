@echo off
setlocal EnableExtensions
title Discord Auto Login - Pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Monitor.ps1" -Pause
echo.
pause
