@echo off
setlocal EnableExtensions
title Discord
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0engine\Monitor.ps1" -Launch
