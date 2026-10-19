@echo off
REM ============================================================
REM  MediaElch Windows one-click build script
REM  Qt 6.7.3 (win64_mingw) + MinGW-w64 gcc 13.1 (tools_mingw1310)
REM ------------------------------------------------------------
REM  Prerequisites:
REM    1. uv installed        https://docs.astral.sh/uv/
REM    2. git in PATH
REM    3. network reachable (curl fails through proxy TLS; script uses Python to download)
REM  Usage:
REM    Run in the MediaElch repo root, in cmd:  build_windows.bat
REM      build_windows.bat              # build + deploy only, no package
REM      build_windows.bat --package    # build + deploy + package dist\*.zip
REM      build_windows.bat -p           # same as --package (short alias)
REM    Legacy usage also works:  set PACKAGE=1  then run this script
REM  Output:
REM    build\MediaElch.exe  (self-contained; double-click to run, or copy whole dir to another Windows machine)
REM    dist\MediaElch-<ver>-windows-x64.zip  (only when --package is given)
REM ============================================================

cd /d "%~dp0"

REM ---- 0. basic checks ----
where uv  >nul 2>&1 || (echo [ERROR] uv not found. Install: https://docs.astral.sh/uv/ & exit /b 1)
where git >nul 2>&1 || (echo [ERROR] git not found & exit /b 1)

REM ---- 0.1 parse argument (--package / -p); also honor legacy set PACKAGE=1 ----
REM Capture any PACKAGE value inherited from parent shell before we reset it
if /I "%PACKAGE%"=="1" (set "PKG_FROM_ENV=1") else (set "PKG_FROM_ENV=0")
set "PACKAGE=0"
if "%PKG_FROM_ENV%"=="1" set "PACKAGE=1"
if /I "%~1"=="--package" set "PACKAGE=1"
if /I "%~1"=="-p" set "PACKAGE=1"
if /I "%~1"=="package" set "PACKAGE=1"
if "%PACKAGE%"=="1" (echo [flag] packaging enabled: dist\*.zip will be produced after build)

REM ---- variables (edit Qt version / paths here if needed) ----
set "QT_ROOT=C:\Qt"
set "QT_VER=6.7.3"
set "MINGW_DIR=%QT_ROOT%\Tools\mingw1310_64"
set "QT_BIN=%QT_ROOT%\%QT_VER%\mingw_64\bin"
set "PKG=third_party\packaging_win"

REM ---- 1. venv + Python build tools ----
echo [1/8] Prepare Python venv (.venv) and build tools
if not exist ".venv\Scripts\activate.bat" (
    uv venv .venv -p 3.13
)
call .venv\Scripts\activate.bat
uv pip install cmake ninja aqtinstall py7zr pefile

REM ---- 2. Qt6 + MinGW toolchain ----
echo [2/8] Install Qt %QT_VER% (win64_mingw) + MinGW gcc 13.1 (tools_mingw1310)
if not exist "%QT_ROOT%\%QT_VER%\mingw_64\lib\cmake\Qt6\Qt6Config.cmake" (
    aqt install-qt windows desktop %QT_VER% win64_mingw -O %QT_ROOT% -m qt5compat qtmultimedia
)
if not exist "%MINGW_DIR%\bin\gcc.exe" (
    aqt install-tool windows desktop tools_mingw1310 -O %QT_ROOT%
)

REM ---- 3. put toolchain on PATH (MinGW + Qt bin with windeployqt / lrelease) ----
set "PATH=%MINGW_DIR%\bin;%QT_BIN%;%PATH%"

REM ---- 4. build-time third-party deps: MediaInfoDLL (24.06) + ZenLib (master) ----
echo [4/8] Fetch MediaInfoDLL and ZenLib (CMake adds project root to include path)
if exist "MediaInfoDLL\MediaInfoDLL.h" goto :deps_done

REM fetch MediaInfoDLL.7z (if missing/broken) + 7zr.exe (if missing) via helper script
python "%~dp0fetch_deps.py" "%PKG%"
if errorlevel 1 (echo [FAIL] dependency download failed & exit /b 1)

REM extract MediaInfoDLL source + runtime dll to project root
if exist "%PKG%\MediaInfo_extract" rmdir /s /q "%PKG%\MediaInfo_extract"
"%PKG%\7zr.exe" x -y -bd -o"%PKG%\MediaInfo_extract" "%PKG%\MediaInfoDLL.7z"
if errorlevel 1 (echo [FAIL] 7zr extraction failed & exit /b 1)
if not exist "%PKG%\MediaInfo_extract\Developers\Source\MediaInfoDLL" (echo [FAIL] MediaInfoDLL source not found inside archive & exit /b 1)
move "%PKG%\MediaInfo_extract\Developers\Source\MediaInfoDLL" "MediaInfoDLL" >nul
if exist "%PKG%\MediaInfo_extract\MediaInfo.dll" move "%PKG%\MediaInfo_extract\MediaInfo.dll" "%PKG%\MediaInfo.dll" >nul
rmdir /s /q "%PKG%\MediaInfo_extract"
if not exist "MediaInfoDLL\MediaInfoDLL.h" (echo [FAIL] MediaInfoDLL\MediaInfoDLL.h missing after extract & exit /b 1)

:deps_done

if exist "ZenLib\Ztring.h" goto :zen_done
echo   - Clone ZenLib (master) -^> ZenLib\
if exist "%PKG%\tmp_ZenLib" rmdir /s /q "%PKG%\tmp_ZenLib"
git clone --depth=1 --branch=master https://github.com/MediaArea/ZenLib.git "%PKG%\tmp_ZenLib"
if errorlevel 1 (echo [FAIL] ZenLib clone failed & exit /b 1)
move "%PKG%\tmp_ZenLib\Source\ZenLib" "ZenLib" >nul
if not exist "ZenLib\Ztring.h" (echo [FAIL] ZenLib\Ztring.h missing after clone & exit /b 1)
rmdir /s /q "%PKG%\tmp_ZenLib"

:zen_done

REM ---- 5. CMake configure ----
echo [5/8] CMake configure (Ninja + Qt%QT_VER% + explicit ZLIB + disable updater)
cmake -G Ninja ^
  -DCMAKE_PREFIX_PATH=%QT_ROOT%\%QT_VER%\mingw_64\lib\cmake ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DDISABLE_UPDATER=ON ^
  -DZLIB_INCLUDE_DIR=%MINGW_DIR%\x86_64-w64-mingw32\include ^
  -DZLIB_LIBRARY=%MINGW_DIR%\x86_64-w64-mingw32\lib\libz.a ^
  -B build .
if %errorlevel% neq 0 (echo [FAIL] CMake configure failed & exit /b 1)

REM ---- 6. build ----
echo [6/8] Build MediaElch (Ninja Release)
cmake --build build --config Release -j
if %errorlevel% neq 0 (echo [FAIL] build failed & exit /b 1)

REM ---- 7. deploy (windeployqt + extra DLLs + remove unused SQL drivers) ----
echo [7/8] Deploy runtime (windeployqt + extra DLLs)
windeployqt --release build\MediaElch.exe
if exist "build\third_party\quazip\quazip\libquazip1-qt6.dll" (
    copy /Y "build\third_party\quazip\quazip\libquazip1-qt6.dll" "build\libquazip1-qt6.dll" >nul
)
if exist "%PKG%\MediaInfo.dll" copy /Y "%PKG%\MediaInfo.dll" "build\MediaInfo.dll" >nul
if exist "%QT_BIN%\Qt6Core5Compat.dll" copy /Y "%QT_BIN%\Qt6Core5Compat.dll" "build\Qt6Core5Compat.dll" >nul
if exist "%QT_BIN%\opengl32sw.dll" copy /Y "%QT_BIN%\opengl32sw.dll" "build\opengl32sw.dll" >nul
REM remove SQL drivers we do not need (avoid missing libpq/mimapi64 client libraries at runtime)
if exist "build\sqldrivers\qsqlpsql.dll" del /F "build\sqldrivers\qsqlpsql.dll"
if exist "build\sqldrivers\qsqlmimer.dll" del /F "build\sqldrivers\qsqlmimer.dll"
if exist "build\sqldrivers\qsqlodbc.dll" del /F "build\sqldrivers\qsqlodbc.dll"

REM ---- 8. (optional) package into zip ----
if "%PACKAGE%"=="1" (
    echo [8/8] Package dist\MediaElch-2.12.1-windows-x64.zip
    python package_windows.py
) else (
    echo [8/8] Skipped packaging. To package, rerun: build_windows.bat --package
)

echo.
echo ============================================================
echo  Build complete!
echo    Executable: %CD%\build\MediaElch.exe
echo    (self-contained; double-click to run, or copy the whole dir to another Windows machine)
if "%PACKAGE%"=="1" (
    echo    Package:    %CD%\dist\MediaElch-2.12.1-windows-x64.zip
)
echo ============================================================
exit /b 0
