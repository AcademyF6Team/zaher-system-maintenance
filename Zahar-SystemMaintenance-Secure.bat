@echo off
setlocal EnableExtensions
chcp 65001 >nul
title Zahar System Maintenance v2.1 - Secure Defensive Edition
set "SCRIPT=%~dp0Zahar-SystemMaintenance-Secure.ps1"
if not exist "%SCRIPT%" (
  echo [ERROR] الملف غير موجود: %SCRIPT%
  pause
  exit /b 1
)
net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo [INFO] طلب صلاحيات المسؤول...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b 0
)
echo [INFO] تشغيل النسخة الأمنية التنفيذية...
echo [INFO] التغييرات الحساسة تتطلب YES ونقطة استعادة.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "EXITCODE=%errorlevel%"
echo.
if "%EXITCODE%"=="0" (echo [OK] انتهت الأداة.) else (echo [WARN] رمز الخروج: %EXITCODE%)
pause
exit /b %EXITCODE%
