@echo off
rem ---------------------------------------------------------------------------
rem Olio IDE launcher.
rem
rem Double-click to open the editor on the olio project, or drag a file/folder
rem onto this script to open that instead.
rem
rem It re-launches itself elevated when it is not already running with
rem administrator rights: managed machines (BeyondTrust Defendpoint, Zscaler,
rem ...) commonly deny writes from unsigned programs unless they are elevated,
rem and then the editor cannot save anything.
rem
rem Set OLIO_NO_ELEVATE=1 to skip the elevation (useful for testing).
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
title Olio IDE

set "OLIO_HOME=%~dp0"
if "%OLIO_HOME:~-1%"=="\" set "OLIO_HOME=%OLIO_HOME:~0,-1%"

if not defined OLIO_NO_ELEVATE (
    whoami /groups | findstr /c:"S-1-16-12288" /c:"S-1-16-16384" >nul 2>nul
    if errorlevel 1 (
        echo Olio needs administrator rights on this machine:
        echo unsigned programs are not allowed to write files without them.
        echo.
        echo Click "Yes" on the Windows prompt to continue.
        set "ELEVARGS="
        if not "%~1"=="" set ELEVARGS=-ArgumentList '"%~1"'
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' %ELEVARGS% -Verb RunAs"
        if errorlevel 1 (
            echo.
            echo Elevation was cancelled - olio would not be able to save files.
            pause
        )
        exit /b
    )
)

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
