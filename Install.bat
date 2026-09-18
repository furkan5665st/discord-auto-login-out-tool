@echo off
setlocal EnableExtensions
title Discord Auto Login - Install
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Monitor.ps1" -Install
echo.
pause
