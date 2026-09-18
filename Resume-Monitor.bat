@echo off
setlocal EnableExtensions
title Discord Auto Login - Resume
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Monitor.ps1" -Resume
echo.
pause
