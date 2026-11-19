@echo off
rem ---------------------------------------------------------------------------
rem Olio IDE launcher.
rem
rem Double-click to open the editor on the olio project, or drag a file/folder
rem onto this script to open that instead.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
title Olio IDE

set "OLIO_HOME=%~dp0"
if "%OLIO_HOME:~-1%"=="\" set "OLIO_HOME=%OLIO_HOME:~0,-1%"

rem The integrated build needs the Odin compiler on PATH.
where odin >nul 2>nul
if errorlevel 1 (
    if exist "%USERPROFILE%\Odin\odin.exe" (
        set "PATH=%PATH%;%USERPROFILE%\Odin"
        set "OLIO_ODIN=%USERPROFILE%\Odin\odin.exe"
    )
)

cd /d "%OLIO_HOME%"

if "%~1"=="" goto run_project
if exist "%~1\" goto run_folder

rem A file was dropped on the launcher: open it.
"%OLIO_HOME%\olio.exe" "%~1"
goto done

:run_folder
cd /d "%~1"
"%OLIO_HOME%\olio.exe"
goto done

:run_project
"%OLIO_HOME%\olio.exe"

:done
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo olio exited with code %RC%
    pause
)
exit /b %RC%
