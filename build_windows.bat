@echo off
REM ============================================================
REM  MediaElch Windows 一键构建脚本
REM  Qt 6.7.3 (win64_mingw) + MinGW-w64 gcc 13.1 (tools_mingw1310)
REM ------------------------------------------------------------
REM  前置条件:
REM    1. 已安装 uv        https://docs.astral.sh/uv/
REM    2. git 在 PATH
REM    3. 网络可通（curl 走代理会 TLS 失败，脚本改用 Python 下载）
REM  用法:
REM    在 MediaElch 仓库根目录，cmd 中执行:
REM      build_windows.bat              # 仅编译 + 部署，不打包
REM      build_windows.bat --package    # 编译 + 部署 + 打包 dist\*.zip
REM      build_windows.bat -p           # 同上，--package 的简写
REM    兼容老用法: 先执行  set PACKAGE=1  再运行本脚本同样会打包
REM  产物:
REM    build\MediaElch.exe  （自包含，可直接双击，或整目录拷到别的 Windows 机器）
REM    dist\MediaElch-<ver>-windows-x64.zip  （仅带 --package 时生成）
REM ============================================================

cd /d "%~dp0"

REM ---- 0. 基本检查 ----
where uv  >nul 2>&1 || (echo [错误] 未找到 uv，请先安装: https://docs.astral.sh/uv/ & exit /b 1)
where git >nul 2>&1 || (echo [错误] 未找到 git & exit /b 1)

REM ---- 0.1 解析参数（--package / -p）；兼容老式 set PACKAGE=1 ----
REM 先捕获可能由父 shell 继承来的 PACKAGE 值，再决定是否覆盖
if /I "%PACKAGE%"=="1" (set "PKG_FROM_ENV=1") else (set "PKG_FROM_ENV=0")
set "PACKAGE=0"
if "%PKG_FROM_ENV%"=="1" set "PACKAGE=1"
if /I "%~1"=="--package" set "PACKAGE=1"
if /I "%~1"=="-p" set "PACKAGE=1"
if /I "%~1"=="package" set "PACKAGE=1"
if "%PACKAGE%"=="1" (echo [参数] 已启用打包: 构建完成后生成 dist\*.zip)

REM ---- 变量（如需改 Qt 版本/路径，改这里即可）----
set "QT_ROOT=C:\Qt"
set "QT_VER=6.7.3"
set "MINGW_DIR=%QT_ROOT%\Tools\mingw1310_64"
set "QT_BIN=%QT_ROOT%\%QT_VER%\mingw_64\bin"
set "PKG=third_party\packaging_win"

REM ---- 1. 虚拟环境 + Python 构建工具 ----
echo [1/8] 准备 Python 虚拟环境 (.venv) 与构建工具
if not exist ".venv\Scripts\activate.bat" (
    uv venv .venv -p 3.13
)
call .venv\Scripts\activate.bat
uv pip install cmake ninja aqtinstall py7zr pefile

REM ---- 2. Qt6 + MinGW 编译器 ----
echo [2/8] 安装 Qt %QT_VER% (win64_mingw) + MinGW gcc 13.1 (tools_mingw1310)
if not exist "%QT_ROOT%\%QT_VER%\mingw_64\lib\cmake\Qt6\Qt6Config.cmake" (
    aqt install-qt windows desktop %QT_VER% win64_mingw -O %QT_ROOT% -m qt5compat qtmultimedia
)
if not exist "%MINGW_DIR%\bin\gcc.exe" (
    aqt install-tool windows desktop tools_mingw1310 -O %QT_ROOT%
)

REM ---- 3. 工具链进 PATH (MinGW + Qt bin 含 windeployqt / lrelease) ----
set "PATH=%MINGW_DIR%\bin;%QT_BIN%;%PATH%"

REM ---- 4. 第三方构建期依赖: MediaInfoDLL (24.06) + ZenLib (master) ----
echo [4/8] 获取 MediaInfoDLL 与 ZenLib（CMake 把项目根加入 include 路径）
if not exist "MediaInfoDLL\MediaInfoDLL.h" (
    if not exist "%PKG%\MediaInfoDLL.7z" (
        echo   - 下载 MediaInfo DLL 24.06 (官方源 mediaarea.net，走代理 TLS 正常)
        python -c "import urllib.request,os; url='https://mediaarea.net/download/binary/libmediainfo0/24.06/MediaInfo_DLL_24.06_Windows_x64_WithoutInstaller.7z'; out=r'%PKG%\MediaInfoDLL.7z'; os.makedirs(os.path.dirname(out),exist_ok=True); open(out,'wb').write(urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'MediaElch-Build'}),timeout=300).read()); print('downloaded',out)"
    )
    if not exist "%PKG%\7zr.exe" (
        echo   - 下载 7zr.exe（解压 BCJ2；py7zr 不支持）
        python -c "import urllib.request,os; url='https://7-zip.org/a/7zr.exe'; out=r'%PKG%\7zr.exe'; os.makedirs(os.path.dirname(out),exist_ok=True); open(out,'wb').write(urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'MediaElch-Build'}),timeout=120).read()); print('downloaded',out)"
    )
    echo   - 解压并摆放到项目根
    if exist "%PKG%\MediaInfo_extract" rmdir /s /q "%PKG%\MediaInfo_extract"
    "%PKG%\7zr.exe" x -y -bd -o"%PKG%\MediaInfo_extract" "%PKG%\MediaInfoDLL.7z"
    move "%PKG%\MediaInfo_extract\Developers\Source\MediaInfoDLL" "MediaInfoDLL" >nul
    if exist "%PKG%\MediaInfo_extract\MediaInfo.dll" move "%PKG%\MediaInfo_extract\MediaInfo.dll" "%PKG%\MediaInfo.dll" >nul
    rmdir /s /q "%PKG%\MediaInfo_extract"
)

if not exist "ZenLib\Ztring.h" (
    echo   - 克隆 ZenLib (master) -^> ZenLib\
    if exist "%PKG%\tmp_ZenLib" rmdir /s /q "%PKG%\tmp_ZenLib"
    git clone --depth=1 --branch=master https://github.com/MediaArea/ZenLib.git "%PKG%\tmp_ZenLib"
    move "%PKG%\tmp_ZenLib\Source\ZenLib" "ZenLib" >nul
    rmdir /s /q "%PKG%\tmp_ZenLib"
)

REM ---- 5. CMake 配置 ----
echo [5/8] CMake 配置 (Ninja + Qt%QT_VER% + ZLIB 显式指定 + 关闭更新器)
cmake -G Ninja ^
  -DCMAKE_PREFIX_PATH=%QT_ROOT%\%QT_VER%\mingw_64\lib\cmake ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DDISABLE_UPDATER=ON ^
  -DZLIB_INCLUDE_DIR=%MINGW_DIR%\x86_64-w64-mingw32\include ^
  -DZLIB_LIBRARY=%MINGW_DIR%\x86_64-w64-mingw32\lib\libz.a ^
  -B build .
if %errorlevel% neq 0 (echo [失败] CMake 配置出错 & exit /b 1)

REM ---- 6. 编译 ----
echo [6/8] 编译 MediaElch (Ninja Release)
cmake --build build --config Release -j
if %errorlevel% neq 0 (echo [失败] 编译出错 & exit /b 1)

REM ---- 7. 部署（windeployqt + 补缺失 DLL + 清理多余驱动）----
echo [7/8] 部署运行库 (windeployqt + 补 DLL)
windeployqt --release build\MediaElch.exe
if exist "build\third_party\quazip\quazip\libquazip1-qt6.dll" (
    copy /Y "build\third_party\quazip\quazip\libquazip1-qt6.dll" "build\libquazip1-qt6.dll" >nul
)
if exist "%PKG%\MediaInfo.dll" copy /Y "%PKG%\MediaInfo.dll" "build\MediaInfo.dll" >nul
if exist "%QT_BIN%\Qt6Core5Compat.dll" copy /Y "%QT_BIN%\Qt6Core5Compat.dll" "build\Qt6Core5Compat.dll" >nul
if exist "%QT_BIN%\opengl32sw.dll" copy /Y "%QT_BIN%\opengl32sw.dll" "build\opengl32sw.dll" >nul
REM 删除用不到的 SQL 驱动（否则运行时会缺失 libpq/mimapi64 等外部客户端库）
if exist "build\sqldrivers\qsqlpsql.dll" del /F "build\sqldrivers\qsqlpsql.dll"
if exist "build\sqldrivers\qsqlmimer.dll" del /F "build\sqldrivers\qsqlmimer.dll"
if exist "build\sqldrivers\qsqlodbc.dll" del /F "build\sqldrivers\qsqlodbc.dll"

REM ---- 8. (可选) 打包分发 zip ----
if "%PACKAGE%"=="1" (
    echo [8/8] 打包 dist\MediaElch-2.12.1-windows-x64.zip
    python package_windows.py
) else (
    echo [8/8] 跳过打包（如需打包分发，重新运行: build_windows.bat --package）
)

echo.
echo ============================================================
echo  构建完成！
echo    可执行文件: %CD%\build\MediaElch.exe
echo    （自包含，可直接双击运行，或整目录拷到别的 Windows 机器）
if "%PACKAGE%"=="1" (
    echo    分发包:     %CD%\dist\MediaElch-2.12.1-windows-x64.zip
)
echo ============================================================
exit /b 0
