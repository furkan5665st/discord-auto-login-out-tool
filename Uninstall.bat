@echo off
setlocal EnableExtensions
title Discord Auto Login - Uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Monitor.ps1" -Uninstall
echo.
pause
