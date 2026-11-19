@echo off
rem ---------------------------------------------------------------------------
rem Build olio in place.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions

set "OLIO_HOME=%~dp0"
if "%OLIO_HOME:~-1%"=="\" set "OLIO_HOME=%OLIO_HOME:~0,-1%"
cd /d "%OLIO_HOME%"

where odin >nul 2>nul
if errorlevel 1 (
    if exist "%USERPROFILE%\Odin\odin.exe" set "PATH=%PATH%;%USERPROFILE%\Odin"
)

echo odin build .
odin build . -out:olio.exe %*
if errorlevel 1 (
    echo.
    echo Build failed.
    echo If it said "don't have access to write to ...olio.exe", this machine
    echo blocks writes from untrusted programs - retrying elevated.
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 1
)

echo Done: "%OLIO_HOME%\olio.exe"