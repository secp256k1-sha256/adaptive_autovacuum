@echo off
rem Build adaptive_autovacuum.dll from an x64 Native Tools Command Prompt; optional arg = PostgreSQL root (default C:\Program Files\PostgreSQL\18).
setlocal

rem Work from the repository root regardless of the invocation directory.
pushd "%~dp0.."

if "%~1"=="" (
    set "PGROOT=C:\Program Files\PostgreSQL\18"
) else (
    set "PGROOT=%~1"
)

if not exist "%PGROOT%\include\server\postgres.h" (
    echo ERROR: PostgreSQL server headers not found under "%PGROOT%\include\server".
    echo Re-run the EDB installer and make sure the development files are selected,
    echo or pass the correct installation root as the first argument.
    popd & exit /b 1
)
if not exist "%PGROOT%\lib\postgres.lib" (
    echo ERROR: "%PGROOT%\lib\postgres.lib" not found - cannot link the extension.
    popd & exit /b 1
)
where cl >nul 2>nul
if errorlevel 1 (
    echo ERROR: cl.exe not on PATH. Open an "x64 Native Tools Command Prompt for VS".
    popd & exit /b 1
)

rem All build outputs stay inside the windows folder.
cl /nologo /LD /MD /O2 /W3 ^
   /D WIN32 /D _WINDOWS /D _CRT_SECURE_NO_WARNINGS ^
   /I"%PGROOT%\include\server\port\win32_msvc" ^
   /I"%PGROOT%\include\server\port\win32" ^
   /I"%PGROOT%\include\server" ^
   /I"%PGROOT%\include" ^
   /Fo"windows\adaptive_autovacuum.obj" ^
   src\adaptive_autovacuum.c ^
   /link /LIBPATH:"%PGROOT%\lib" postgres.lib ^
   /OUT:"windows\adaptive_autovacuum.dll" ^
   /IMPLIB:"windows\adaptive_autovacuum.lib"
if errorlevel 1 (
    echo BUILD FAILED
    popd & exit /b 1
)

echo.
echo Built windows\adaptive_autovacuum.dll
echo.
echo Install into the running cluster (elevated prompt required):
echo   copy windows\adaptive_autovacuum.dll         "%PGROOT%\lib\"
echo   copy adaptive_autovacuum.control             "%PGROOT%\share\extension\"
echo   copy sql\adaptive_autovacuum--1.0.0.sql      "%PGROOT%\share\extension\"
echo.
echo Then follow the Windows installation steps in the README.
popd
endlocal
