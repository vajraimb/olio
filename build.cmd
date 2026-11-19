@echo off
rem ---------------------------------------------------------------------------
rem Build olio and install it where this machine trusts it.
rem
rem The application-control agent grants a normal token only to executables in
rem %OLIO_TRUSTED_DIR%, so that is where the binary has to live for the editor
rem to be able to save files without administrator rights.
rem
rem Usage:  build.cmd            build + install
rem         build.cmd -debug     build with -debug and install
rem ---------------------------------------------------------------------------
setlocal EnableExtensions

set "OLIO_HOME=%~dp0"
if "%OLIO_HOME:~-1%"=="\" set "OLIO_HOME=%OLIO_HOME:~0,-1%"
if not defined OLIO_TRUSTED_DIR set "OLIO_TRUSTED_DIR=%USERPROFILE%\.zcode\workspace\olio"

cd /d "%OLIO_HOME%"

echo [1/2] odin build .
odin build . -out:olio.exe %*
if errorlevel 1 (
    echo.
    echo Build failed.
    pause
    exit /b 1
)

echo [2/2] installing to "%OLIO_TRUSTED_DIR%"
if not exist "%OLIO_TRUSTED_DIR%\" mkdir "%OLIO_TRUSTED_DIR%" >nul 2>nul
copy /y "%OLIO_HOME%\olio.exe" "%OLIO_TRUSTED_DIR%\olio.exe" >nul
if errorlevel 1 (
    echo.
    echo Could not copy olio.exe to "%OLIO_TRUSTED_DIR%".
    echo Saving will not work from an untrusted folder.
    pause
    exit /b 1
)

echo.
echo Done. Start the editor with launch-ide.cmd or the Desktop shortcut.
