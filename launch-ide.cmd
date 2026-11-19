@echo off
rem ---------------------------------------------------------------------------
rem Olio IDE launcher - deliberately dumb: it just runs the installed copy.
rem
rem olio has to live under %OLIO_TRUSTED_DIR% because this machine's
rem application-control agent only gives a normal (non-restricted) token to
rem executables in that folder. `build.cmd` installs the binary there; this
rem script only starts it.
rem
rem Set OLIO_NO_ELEVATE=1 to never ask for elevation.
rem Set OLIO_TRUSTED_DIR to override the trusted location.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
title Olio IDE

set "OLIO_HOME=%~dp0"
if "%OLIO_HOME:~-1%"=="\" set "OLIO_HOME=%OLIO_HOME:~0,-1%"

if not defined OLIO_TRUSTED_DIR set "OLIO_TRUSTED_DIR=%USERPROFILE%\.zcode\workspace\olio"

set "OLIO_EXE=%OLIO_TRUSTED_DIR%\olio.exe"
if not exist "%OLIO_EXE%" (
    rem Not installed yet: fall back to the freshly built binary in the project.
    set "OLIO_EXE=%OLIO_HOME%\olio.exe"
    if not defined OLIO_NO_ELEVATE (
        whoami /groups | findstr /c:"S-1-16-12288" /c:"S-1-16-16384" >nul 2>nul
        if errorlevel 1 (
            echo olio has not been installed to the trusted folder yet and this
            echo machine blocks file writes from untrusted programs.
            echo.
            echo Run build.cmd once, or click "Yes" to continue elevated.
            set "ELEVARGS="
            if not "%~1"=="" set ELEVARGS=-ArgumentList '"%~1"'
            powershell -NoProfile -Command "Start-Process -FilePath '%~f0' %ELEVARGS% -Verb RunAs"
            exit /b
        )
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

"%OLIO_EXE%" "%~1"
goto done

:run_folder
cd /d "%~1"
"%OLIO_EXE%"
goto done

:run_project
"%OLIO_EXE%"

:done
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo olio exited with code %RC%
    pause
)
exit /b %RC%
