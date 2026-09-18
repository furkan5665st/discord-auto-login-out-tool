@echo off
setlocal EnableExtensions
title Discord Auto Login - Status
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Monitor.ps1" -Status
echo.
pause
