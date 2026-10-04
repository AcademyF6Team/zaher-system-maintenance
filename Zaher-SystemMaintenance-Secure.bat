@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
title Zaher System Maintenance v3.0 - Secure Defensive Edition

set "SCRIPT=%~dp0Zaher-SystemMaintenance-Secure.ps1"
set "HASHFILE=%~dp0Zaher-SystemMaintenance-Secure.ps1.sha256"

REM ============ فحص وجود السكربت ============
if not exist "%SCRIPT%" (
  echo [ERROR] الملف غير موجود: %SCRIPT%
  pause
  exit /b 1
)

REM ============ فحص صلاحيات المسؤول عبر SID ============
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 1 } } catch { exit 1 }" >nul 2>&1

if errorlevel 1 (
  echo [INFO] طلب صلاحيات المسؤول...
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { Start-Process -FilePath $env:ComSpec -ArgumentList '/c','\"\"%~f0\"\" %*' -Verb RunAs } catch { Write-Host '[ERROR] فشل رفع الصلاحيات:' $_.Exception.Message; exit 1 }"
  if errorlevel 1 (
    echo [WARN] لم يتم منح الصلاحيات. تشغيل في وضع AuditOnly...
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -AuditOnly %*
    pause
    exit /b %errorlevel%
  )
  exit /b 0
)

REM ============ فحص سلامة السكربت ============
if exist "%HASHFILE%" (
  echo [INFO] التحقق من سلامة السكربت...
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
    "$ErrorActionPreference='Stop'; try { $raw=(Get-Content -LiteralPath '%HASHFILE%' -Raw).Trim(); $expected=($raw -split '\s+')[0].ToUpper(); $actual=(Get-FileHash -LiteralPath '%SCRIPT%' -Algorithm SHA256).Hash.ToUpper(); if ($expected -ne $actual) { Write-Host '[ERROR] عدم تطابق البصمة!'; Write-Host ('Expected: ' + $expected); Write-Host ('Actual:   ' + $actual); exit 2 }; Write-Host ('[OK] البصمة صحيحة: ' + $actual) } catch { Write-Host ('[ERROR] فشل التحقق: ' + $_.Exception.Message); exit 3 }"
  if errorlevel 2 (
    echo [ERROR] تم إيقاف التشغيل بسبب فشل التحقق من السلامة.
    pause
    exit /b 2
  )
  if errorlevel 3 (
    echo [WARN] لم يتم التحقق. استمرار بعد 3 ثوانٍ...
    timeout /t 3 /nobreak >nul
  )
) else (
  echo [WARN] لا يوجد ملف بصمة: %HASHFILE%
  echo [WARN] يُنصح بإنشائه بعد كل تعديل.
  timeout /t 3 /nobreak >nul
)

REM ============ تشغيل السكربت ============
echo [INFO] تشغيل Zaher System Maintenance v3.0...
echo [INFO] التغييرات الحساسة تتطلب YES + Restore Point.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "EXITCODE=%errorlevel%"
echo.
if "%EXITCODE%"=="0" (echo [OK] انتهت الأداة.) else (echo [WARN] رمز الخروج: %EXITCODE%)
pause
exit /b %EXITCODE%