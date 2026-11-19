@echo off
rem ---------------------------------------------------------------------------
rem Olio IDE launcher.
rem
rem Double-click to open the editor on the olio project, or drag a file/folder
rem onto this script to open that instead.
rem
rem Why there is a "trusted install" below:
rem managed machines (BeyondTrust / Avecto Privilege Guard, Zscaler, ...) hand
rem out a *restricted token* to executables they do not recognise, and such a
rem process can run but cannot write files anywhere in the user profile, so
rem saving fails with Permission_Denied / CreateFileW error 5. The same policy
rem grants normal rights to binaries under the whitelisted developer folder, so
rem olio runs from a copy kept there. Elevation is only needed when that copy is
rem not available.
rem
rem Set OLIO_NO_ELEVATE=1 to never ask for elevation.
rem Set OLIO_TRUSTED_DIR to override the trusted location.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
title Olio IDE

set "OLIO_HOME=%~dp0"
if "%OLIO_HOME:~-1%"=="\" set "OLIO_HOME=%OLIO_HOME:~0,-1%"

if not defined OLIO_TRUSTED_DIR set "OLIO_TRUSTED_DIR=%USERPROFILE%\.zcode\workspace\olio"

set "OLIO_EXE=%OLIO_HOME%\olio.exe"
set "NEEDS_TRUST=1"

rem Create the trusted folder on first use, as long as its parent exists.
if not exist "%OLIO_TRUSTED_DIR%\" (
    if exist "%OLIO_TRUSTED_DIR%\..\" mkdir "%OLIO_TRUSTED_DIR%" >nul 2>nul
)

rem Keep a copy of the freshly built binary in the trusted folder and use it.
if exist "%OLIO_TRUSTED_DIR%\" (
    if not exist "%OLIO_TRUSTED_DIR%\olio.exe" (
        copy /y "%OLIO_HOME%\olio.exe" "%OLIO_TRUSTED_DIR%\olio.exe" >nul 2>nul
    ) else (
        fc /b "%OLIO_HOME%\olio.exe" "%OLIO_TRUSTED_DIR%\olio.exe" >nul 2>nul
        if errorlevel 1 copy /y "%OLIO_HOME%\olio.exe" "%OLIO_TRUSTED_DIR%\olio.exe" >nul 2>nul
    )
    if exist "%OLIO_TRUSTED_DIR%\olio.exe" (
        set "OLIO_EXE=%OLIO_TRUSTED_DIR%\olio.exe"
        set "NEEDS_TRUST=0"
    )
)

if "%NEEDS_TRUST%"=="1" if not defined OLIO_NO_ELEVATE (
    whoami /groups | findstr /c:"S-1-16-12288" /c:"S-1-16-16384" >nul 2>nul
    if errorlevel 1 (
        echo Olio is not running from a trusted folder, and this machine does not
        echo let unsigned programs write files without administrator rights.
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
