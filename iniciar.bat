@echo off
setlocal
cd /d "%~dp0"
title MariaDB Multi-Database Manager

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0mariadb_manager.ps1"

if errorlevel 1 (
    echo.
    echo O script foi encerrado com erro.
    pause
)
