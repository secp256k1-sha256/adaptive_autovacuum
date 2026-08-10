@echo off
rem ---------------------------------------------------------------------------
rem Build adaptive_autovacuum.dll against an existing PostgreSQL installation
rem (for example the EDB installer's default location).
rem
rem Run from an "x64 Native Tools Command Prompt for VS"
rem (Visual Studio 2019/2022 Build Tools are sufficient).
rem
rem Usage:
rem   build_windows.bat                         (assumes C:\Program Files\PostgreSQL\18)
rem   build_windows.bat "D:\PostgreSQL\18"      (custom installation root)
rem ---------------------------------------------------------------------------
setlocal

if "%~1"=="" (
    set "PGROOT=C:\Program Files\PostgreSQL\18"
) else (
    set "PGROOT=%~1"
)

if not exist "%PGROOT%\include\server\postgres.h" (
    echo ERROR: PostgreSQL server headers not found under "%PGROOT%\include\server".
    echo Re-run the EDB installer and make sure the development files are selected,
    echo or pass the correct installation root as the first argument.
    exit /b 1
)
if not exist "%PGROOT%\lib\postgres.lib" (
    echo ERROR: "%PGROOT%\lib\postgres.lib" not found - cannot link the extension.
    exit /b 1
)
where cl >nul 2>nul
if errorlevel 1 (
    echo ERROR: cl.exe not on PATH. Open an "x64 Native Tools Command Prompt for VS".
    exit /b 1
)

cl /nologo /LD /MD /O2 /W3 ^
   /D WIN32 /D _WINDOWS /D _CRT_SECURE_NO_WARNINGS ^
   /I"%PGROOT%\include\server\port\win32_msvc" ^
   /I"%PGROOT%\include\server\port\win32" ^
   /I"%PGROOT%\include\server" ^
   /I"%PGROOT%\include" ^
   src\adaptive_autovacuum.c ^
   /link /LIBPATH:"%PGROOT%\lib" postgres.lib /OUT:adaptive_autovacuum.dll
if errorlevel 1 (
    echo BUILD FAILED
    exit /b 1
)

echo.
echo Built adaptive_autovacuum.dll
echo.
echo Install into the running cluster (elevated prompt required):
echo   copy adaptive_autovacuum.dll                 "%PGROOT%\lib\"
echo   copy adaptive_autovacuum.control             "%PGROOT%\share\extension\"
echo   copy sql\adaptive_autovacuum--1.0.0.sql      "%PGROOT%\share\extension\"
echo.
echo Then follow the Windows installation steps in the README.
endlocal
