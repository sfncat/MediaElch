# MediaElch Windows 编译手册（Qt6 + CMake + MinGW）【实测验证版】

> 适用对象：从源码编译 **MediaElch** 并在 Windows 上跑起来试用。
> 目标仓库：`sfncat/MediaElch`（你自己的 fork，`master` 分支，版本 **2.12.1**）。
> 构建系统：**CMake + Ninja**（官方已弃用 qmake / Qt Creator 图形构建；`CMakePresets.json` 提供 `release` 预设，生成器为 Ninja）。
> 框架：**Qt6**（实测 6.7.3，MinGW-w64 gcc 13.1.0）。
>
> ✅ **本手册基于 sfncat fork master / 2.12.1 于 2026-10-19 在 Windows 上完整实测通过**（编译 → 部署 → 依赖完整性 PE 校验：零缺失）。下文所有命令均来自成功路径。凡标注「⚠️ 实测修正」处，均为与原 GitHub 旧文档 / 本手册早期草稿不符、踩坑后纠正的内容。

---

## 0. 快速开始：用 build_windows.bat 一键编译打包（推荐）

不想逐步敲命令？仓库根目录已提供 **`build_windows.bat`** 一键脚本，把本手册 §3（准备工具）、§5（配置）、§6（编译）、§7（部署）等全流程固化，其中 §3.3 的 **MediaInfoDLL / ZenLib** 构建期依赖也由脚本自动下载摆放。第一次运行会下载 Qt6（约 1.2 GB），请预留网络与时间；后续增量构建很快。

**前置条件（一次性）：**
- 已安装 [`uv`](https://docs.astral.sh/uv/)（`uv venv` 用它建 `.venv`）
- `git` 在 PATH
- 网络可通（脚本内下载走 Python `urllib`，**不要**用 `curl`——本机代理下 `curl` 走 schannel 会 TLS 握手失败，见 §3.3）

**用法（在 `MediaElch\` 仓库根目录，cmd 中执行）：**

| 命令 | 作用 |
|---|---|
| `build_windows.bat` | 仅**编译 + 部署**成可运行目录 `build\`，不打包 |
| `build_windows.bat --package`（简写 `-p` / `package`） | 编译 + 部署 **+ 打包** 分发 zip |
| `set PACKAGE=1` 然后 `build_windows.bat` | 老式环境变量写法，效果等同 `--package` |

```bat
cd C:\workspace\mediaInfo\MediaElch
build_windows.bat --package
```

**脚本内部自动完成的 8 步（幂等，可重复跑）：**
1. `uv venv .venv -p 3.13` + `uv pip install cmake ninja aqtinstall py7zr pefile`（构建工具进虚拟环境）
2. `aqt install-qt` 装 **Qt 6.7.3 win64_mingw**（`-m qt5compat qtmultimedia`）+ `aqt install-tool` 装 **MinGW-w64 gcc 13.1.0**（`tools_mingw1310`）
3. 把 MinGW / Qt `bin` 加进 `PATH`（含 `windeployqt` / `lrelease`）
4. 下载 **MediaInfoDLL 24.06** 头文件 + **ZenLib** 头文件，摆到项目根（构建期硬依赖，见 §3.3）。下载实际由辅助脚本 **`fetch_deps.py`** 完成：它校验 `MediaInfoDLL.7z` 体积（缺失或 <1 MB 视为损坏重新下载）、并下载 `7zr.exe`（py7zr 不支持 BCJ2），随后 `7zr` 解压出头文件与 `MediaInfo.dll`、`git clone` ZenLib；任何一步失败都会明确报错退出，不会再静默继续。
5. `cmake -G Ninja` 配置（`CMAKE_PREFIX_PATH` + 显式 ZLIB 静态库路径 + `DISABLE_UPDATER=ON`）
6. `cmake --build build` 编译 Release
7. `windeployqt --release` + 手动补 `libquazip1-qt6.dll` / `Qt6Core5Compat.dll` / `opengl32sw.dll` / `MediaInfo.dll` + 删多余 SQL 驱动（见 §7）
8. （仅 `--package`）调用 `package_windows.py` 选择性打包 `build\` → `dist\MediaElch-2.12.1-windows-x64.zip`

**产物：**
- 可执行程序：`build\MediaElch.exe`（自包含，双击即可运行，或整目录拷到别的 Windows 机器）
- 分发包（仅 `--package`）：`dist\MediaElch-2.12.1-windows-x64.zip`（约 44 MB，已剔除编译垃圾；PE 依赖校验零缺失，可直接分发）

> 想了解每一步背后的原理、手动命令、或排查单个报错，继续看后面的分节（§1 前提、§3 准备工具、§5 配置、§6 编译、§7 部署、§10 排查）。

---

## 1. 重要前提（与官网旧文档、早期草案的区别）

1. **官网 `mediaelch.github.io` 的 Windows 文档是过时的**：写的是 Qt 5.15.2 + qmake + Qt Creator 图形点按钮。当前 master 已改用 **CMake + Qt6**。
2. **⚠️ 实测修正：MediaInfo / ZenLib 是「构建期依赖」，不是运行时才需要。**
   源码 `src/media/MediaInfoFile.cpp` 第 9–10 行直接 `#include "MediaInfoDLL/MediaInfoDLL.h"` 与 `#include <ZenLib/Ztring.h>`，`cmake/MediaElchMisc.cmake` 把项目根目录加入 include path。因此这两个目录**必须**放在 `MediaElch/` 根，且**编译前就要就位**，否则编译必败。早期草案说"只是运行时动态加载"是错误的。
3. **本机（127.0.0.1 代理环境）实测 PyPI / aqt / git 联网正常**；仅 `curl` 走 Windows schannel 与代理 HTTPS 握手失败（见 §3.3 下载替代方案）。早期草案"本机离线"也是错的。

---

## 2. 依赖总览

| 类别 | 依赖 | 说明 |
|---|---|---|
| 构建期必须 | CMake ≥ 3.15 | 构建系统（实测装到 cmake 4.4.4） |
| 构建期必须 | Ninja | 生成器（实测 ninja 1.13.2） |
| 构建期必须 | C++17 编译器 | **MinGW-w64 gcc 13.1.0**（务必用 aqt 的 `tools_mingw1310`，不要混系统其他 MinGW） |
| 构建期必须 | Qt6.7.3（mingw_64） | GUI 框架 |
| 构建期必须 | ZLIB（静态） | **MinGW 工具链自带**（`libz.a`），需 CMake 显式指定路径（见 §5） |
| 构建期必须 | MediaInfoDLL（头文件） | 来自 MediaInfo DLL 官方包，放项目根 `./MediaInfoDLL/`（⚠️ 早期草案漏写） |
| 构建期必须 | ZenLib（头文件） | 来自 ZenLib 源码 `Source/ZenLib`，放项目根 `./ZenLib/`（⚠️ 早期草案漏写） |
| 构建期已自带 | QuaZip 1.4 | git submodule（`third_party/quazip`），无需单独装；但编译产物 `libquazip1-qt6.dll` 需手动部署（见 §7） |
| 运行时必须 | MediaInfo.dll | 读取视频元数据，放 exe 同目录（来自同一个 7z 包） |
| 运行时可选 | ffmpeg.exe | 仅视频截图功能需要 |
| 运行时自动 | Qt 运行库 | 由 `windeployqt` 自动拷贝 |

**Qt6 组件 → aqtinstall 模块（⚠️ 实测修正）：**

> aqt 的 `-m` 只接收**附加模块名**，不能写 `qtbase`/`qtsvg`/`linguist`（这些要么是默认基础包、要么是 tools，列出来反而报 `were not found while parsing XML` 导致整体失败）。实测只需 `-m qt5compat qtmultimedia`，**Qt6Svg 随 base 自动安装**（已验证 `Qt6Svg.dll` 存在）。

| 实际安装内容 | 来源 |
|---|---|
| qtbase + qtsvg + qtdeclarative + qttools + qtmultimedia + qt5compat + qttranslations + MinGW 运行库 | `aqt install-qt ... -m qt5compat qtmultimedia`（base 自动含其余） |

---

## 3. 准备工具（一次性，需外网）

前置：Git（已装）、**uv**（已用 `uv venv .venv -p 3.13` 创建虚拟环境，假定 `uv` 在 PATH）。
⚠️ 本机 Python 相关构建工具**一律用 `uv pip install` 装进 `.venv`**，不用系统 `pip`（用户约定）。

### 3.1 用 uv 装构建工具（cmake / ninja / aqtinstall）

```bat
cd C:\workspace\mediaInfo\MediaElch
.venv\Scripts\activate
uv pip install cmake ninja aqtinstall
cmake --version && ninja --version && aqt version
```
> 三个 exe 落在 `.venv\Scripts\`，**只有 venv 激活时**才在 PATH。建议整个编译过程保持 venv 激活。
> `aqt` 没有 `--version` 参数，查版本用 `aqt version`。

### 3.2 用 aqtinstall 安装 Qt6 + 匹配 MinGW

⚠️ **实测修正**：装到 `C:\Qt`（**不是** `D:\Qt`——`D:` 实测是 WinPE 启动恢复卷，不可写）；编译器用 **`tools_mingw1310`**（gcc 13.1.0），不要用 `tools_mingw`（那是 gcc 8.1/7.3，太老会 ABI 不兼容）。

```bat
cd C:\workspace\mediaInfo\MediaElch
.venv\Scripts\activate
set QT_ROOT=C:\Qt
aqt install-qt windows desktop 6.7.3 win64_mingw -O %QT_ROOT% -m qt5compat qtmultimedia
aqt install-tool windows desktop tools_mingw1310 -O %QT_ROOT%
```
> `-m qt5compat qtmultimedia` 触发 base（含 Qt6Svg）全量安装，约 1.2 GB，视网速几分钟。

把 MinGW 的 `bin` 加进 PATH（gcc 实际路径 `C:\Qt\Tools\mingw1310_64\bin`）：
```bat
set PATH=C:\Qt\Tools\mingw1310_64\bin;%PATH%
gcc --version
```

### 3.3 第三方构建期依赖：MediaInfoDLL + ZenLib（⚠️ 关键，早期草案漏写）

> ⚠️ 若用 `build_windows.bat` 一键脚本，本节的下载 / 解压已**自动由 `fetch_deps.py` 完成**（含体积校验与失败报错），无需手动执行下面命令；本小节保留作手动备用与原理说明。

这两个**必须在 CMake 配置前就位**，否则编译在 `MediaInfoFile.cpp` 处 `fatal error: MediaInfoDLL/MediaInfoDLL.h: No such file`。

**A. MediaInfoDLL（头文件）+ MediaInfo.dll（运行时）**

官方 CI 同款：下载 MediaInfo DLL 包 24.06 → 解压出 `Developers/Source/MediaInfoDLL` 与 `MediaInfo.dll`。

- 官方源（推荐，走代理稳定）：
  `https://mediaarea.net/download/binary/libmediainfo0/24.06/MediaInfo_DLL_24.06_Windows_x64_WithoutInstaller.7z`
  SHA512 = `7b71110ad0ca643e52c3390ba9bd7615c4c077bba84b3a68c9b05b28e90bce8670c0905863cb7dca359118cbb64dca324bac97262925ae555eeeac0e722bcd5a`
- 解压工具：用官方 standalone `7zr.exe`（`https://7-zip.org/a/7zr.exe`）。⚠️ 不要用 `py7zr`——该 7z 包用 BCJ2 压缩，py7zr 不支持会报错。

```bat
cd C:\workspace\mediaInfo\MediaElch
.venv\Scripts\activate
:: 若 curl 在代理下失败（schannel 握手错），改用浏览器下载上述两个文件，或：
python -c "import urllib.request; urllib.request.urlretrieve('https://7-zip.org/a/7zr.exe','third_party/packaging_win/7zr.exe')"
python -c "import urllib.request; urllib.request.urlretrieve('https://mediaarea.net/download/binary/libmediainfo0/24.06/MediaInfo_DLL_24.06_Windows_x64_WithoutInstaller.7z','third_party/packaging_win/MediaInfoDLL.7z')"
:: 校验（可选但推荐）
certutil -hashfile third_party/packaging_win/MediaInfoDLL.7z SHA512
:: 解压并摆放
third_party\packaging_win\7zr.exe x -y -bd -othird_party\packaging_win\MediaInfo_extract third_party\packaging_win\MediaInfoDLL.7z
rmdir /s /q MediaInfoDLL
move third_party\packaging_win\MediaInfo_extract\Developers\Source\MediaInfoDLL MediaInfoDLL
move third_party\packaging_win\MediaInfo_extract\MediaInfo.dll third_party\packaging_win\MediaInfo.dll
```

**B. ZenLib（头文件）**

```bat
cd C:\workspace\mediaInfo\MediaElch
git clone --depth=1 --branch=master https://github.com/MediaArea/ZenLib.git tmp_ZenLib
rmdir /s /q ZenLib
move tmp_ZenLib\Source\ZenLib ZenLib
rmdir /s /q tmp_ZenLib
```

**验证三者到位：**
```bat
dir MediaInfoDLL\MediaInfoDLL.h
dir ZenLib\Ztring.h
dir third_party\packaging_win\MediaInfo.dll
```

---

## 4. 获取源码（换机器重做）

```bat
git clone git@github.com:sfncat/MediaElch.git
cd MediaElch
git submodule update --init
```
> ⚠️ `git submodule update --init` **必须执行**，否则 `third_party/quazip` 缺失，CMake 配置报 quazip 找不到。（实测本机该子模块已初始化，但换机器要跑。）
> 然后回到 §3.3 把 MediaInfoDLL / ZenLib 也放进项目根。

---

## 5. 配置（CMake）【⚠️ 实测修正：补 ZLIB + MinGW PATH】

`CMakePresets.json` 的 `release` 预设**不含** `CMAKE_PREFIX_PATH` 与 `DISABLE_UPDATER`，且 QuaZip 需要 ZLIB（MinGW 自带的 `libz.a` 藏在 `x86_64-w64-mingw32/` 子目录，CMake 不会自动搜到）。

**方式 A（手动，推荐，实测成功路径）：**
```bat
cd C:\workspace\mediaInfo\MediaElch
.venv\Scripts\activate
set PATH=C:\Qt\Tools\mingw1310_64\bin;%PATH%
set QT_ROOT=C:\Qt
cmake -G Ninja ^
  -DCMAKE_PREFIX_PATH=%QT_ROOT%\6.7.3\mingw_64\lib\cmake ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DDISABLE_UPDATER=ON ^
  -DZLIB_INCLUDE_DIR=%QT_ROOT%\Tools\mingw1310_64\x86_64-w64-mingw32\include ^
  -DZLIB_LIBRARY=%QT_ROOT%\Tools\mingw1310_64\x86_64-w64-mingw32\lib\libz.a ^
  -B build .
```
> 配置成功标志：`Using Qt 6.7.3`、`Found ZLIB 1.2.13`、`Configuring done / Generating done`，退出码 0，`build\` 构建树生成。
> Vulkan / Doxygen 缺失只是**警告**，不影响编译；Tests 默认关。

**方式 B（用官方预设）：** 预设不含上面三项，需自己补：
```bat
set CMAKE_PREFIX_PATH=C:\Qt\6.7.3\mingw_64\lib\cmake
cmake --preset release -DDISABLE_UPDATER=ON -DZLIB_INCLUDE_DIR=... -DZLIB_LIBRARY=...
```

---

## 6. 编译

```bat
cd C:\workspace\mediaInfo\MediaElch
.venv\Scripts\activate
set PATH=C:\Qt\Tools\mingw1310_64\bin;%PATH%
cmake --build build --config Release -j
```
或（用了预设）：
```bat
cmake --build --preset release -j
```

产物：
- 方式 A：`build\MediaElch.exe`（实测 12.7 MB，连同 `build\src\cli\mediaelch_cli.exe`）
- 方式 B：`build\release\MediaElch.exe`

首次编译约 **5–20 分钟**（全量 588 个目标）。`BUILD_EXIT=0` 即成功。

---

## 7. 部署成可运行程序（windeployqt + 手动补几项）

```bat
cd C:\workspace\mediaInfo\MediaElch
.venv\Scripts\activate
set PATH=C:\Qt\6.7.3\mingw_64\bin;%PATH%
windeployqt --release build\MediaElch.exe
```
会在 exe 同目录生成 Qt6 各模块 DLL、`platforms\qwindows.dll`、`imageformats\`、`translations\` 等。

**⚠️ 实测修正：windeployqt 会漏以下几项，必须手动补（否则启动报缺 DLL / 黑屏）：**
```bat
:: 1) QuaZip 子模块编译出的动态库（windeployqt 只扫 exe 同目录，漏了它）
copy build\third_party\quazip\quazip\libquazip1-qt6.dll build\libquazip1-qt6.dll
:: 2) Qt5Compat 运行库（某 Qt 模块运行时间接加载，windeployqt 漏部署；缺它会报"找不到 Qt6Core5Compat.dll"）
copy C:\Qt\6.7.3\mingw_64\bin\Qt6Core5Compat.dll build\Qt6Core5Compat.dll
:: 3) 软件 OpenGL 回退（防无独显机器黑屏）
copy C:\Qt\6.7.3\mingw_64\bin\opengl32sw.dll build\opengl32sw.dll
:: 4) MediaInfo.dll（运行时读元数据必需）
copy third_party\packaging_win\MediaInfo.dll build\MediaInfo.dll
:: 5) 删掉用不到的 SQL 驱动（MediaElch 只用 SQLite），避免 libpq/mimapi64 加载噪音与多余体积
::    windeployqt 会把 pg/mimer/odbc 驱动一并部署，但其原生客户端库(libpq/mimapi64) Qt 不提供、必缺
if exist build\sqldrivers\qsqlpsql.dll del build\sqldrivers\qsqlpsql.dll
if exist build\sqldrivers\qsqlmimer.dll del build\sqldrivers\qsqlmimer.dll
if exist build\sqldrivers\qsqlodbc.dll del build\sqldrivers\qsqlodbc.dll
```

**依赖完整性自检（强烈建议，硬验证）：** ⚠️ 只扫 exe 不够——`Qt6Core5Compat` 等被 Qt 模块运行时间接加载，不在 exe 直接导入表，**必须扫 `build\` 下所有 exe/dll**（在 Git Bash 中执行）：
```bash
.venv/Scripts/activate
python - <<'PY'
import os, pefile
build="build"; qtbin=r"C:\Qt\6.7.3\mingw_64\bin"
sysdirs=[r"C:\Windows\System32", r"C:\Windows\SysWOW64"]
pe_files=[os.path.join(r,d,f) for r,ds,fs in os.walk(build) for f in fs if f.lower().endswith(('.exe','.dll'))]
needed=set()
for pf in pe_files:
    try:
        pe=pefile.PE(pf)
        if hasattr(pe,'DIRECTORY_ENTRY_IMPORT'):
            for e in pe.DIRECTORY_ENTRY_IMPORT: needed.add(e.dll.decode().lower())
    except: pass
miss=[n for n in sorted(needed) if not (os.path.exists(os.path.join(build,n)) or any(os.path.exists(os.path.join(s,n)) for s in sysdirs))]
print("非系统缺失:", [x for x in miss if not x.startswith('api-ms-win')])
print("api-ms-win 系统API集(可忽略):", sum(1 for x in miss if x.startswith('api-ms-win')))
PY
```
> `api-ms-win-*` 是 Windows 系统 API 集，运行时由系统自动转发，任何正常 Windows 机器都有，**可忽略**；除此之外应为空。

---

## 8. 运行时依赖（让功能完整）

- **MediaInfo.dll（必放，已在 §7 拷贝）**：读取视频文件元数据，缺它则读不到分辨率/编码/音轨。
- **ffmpeg.exe（可选，仅视频截图）**：下载 Windows 版 ffmpeg（如 https://www.gyan.dev/ffmpeg/builds/ essentials 版），放 exe 同级的 `vendor\ffmpeg.exe`。
- **opengl32sw.dll（已在 §7 拷贝）**：软件渲染回退，防启动黑屏/OpenGL 报错。

---

## 9. 运行与验证

在 **Windows 桌面双击** `C:\workspace\mediaInfo\MediaElch\build\MediaElch.exe`（GUI 程序，需真实桌面会话）。
> ⚠️ 在 headless 的终端里直接跑 exe 会报 127（无法拉起 GUI 进程），**不代表 exe 损坏**——以真机双击能否开主窗为准。
导入一个影片目录试刮削，确认元数据能正常读取（需 §7 的 MediaInfo.dll）。

---

## 10. 常见问题排查

- **CMake 找不到 Qt**：确认 `CMAKE_PREFIX_PATH` 指向 `...\mingw_64\lib\cmake`，且该目录有 `Qt6\Qt6Config.cmake`（⚠️ 在子目录 `Qt6\` 下，不是扁平的 `Qt6Config.cmake`）。
- **Could NOT find ZLIB**：MinGW 自带的 `libz.a` 不在默认搜索路径。按 §5 显式加 `-DZLIB_INCLUDE_DIR` / `-DZLIB_LIBRARY`（指向 `mingw1310_64\x86_64-w64-mingw32\{include,lib}`）。
- **`fatal error: MediaInfoDLL/MediaInfoDLL.h` 或 `ZenLib/Ztring.h`**：§3.3 的第三方依赖没放项目根。回去把 `MediaInfoDLL/`、`ZenLib/` 摆到 `MediaElch/` 根再重新配置编译。
- **`Ninja: cc1plus` / 编译器找不到**：MinGW `bin` 没进 PATH，或 aqt 装的 mingw 与 Qt 的 mingw **ABI 不一致**（务必用 `tools_mingw1310`，不要混用系统其他 MinGW）。
- **启动报缺 `libquazip1-qt6.dll` 或黑屏**：§7 的手动补拷漏了。确认 `build\libquazip1-qt6.dll` 与 `build\opengl32sw.dll` 已就位。
- **LTO 链接极慢 / 爆内存**：release 预设开了 `ENABLE_LTO`；手动配置时不加该开关即可。
- **quazip 缺失报错**：没跑 `git submodule update --init`。
- **curl 下载失败（`schannel: failed to receive handshake`）**：本机走 127.0.0.1 代理时 `curl` 的 Windows schannel 与 HTTPS 隧道握手失败。改用浏览器直接下载，或 §3.3 的 `python -c urllib.request` 方式（Python TLS 栈正常）。`uv`/`aqt`/`git` 不受影响。
- **启动无界面 / 黑屏**：Qt 插件没拷全 → 重跑 `windeployqt`；仍不行就在 exe 同目录放 `opengl32sw.dll`。

---

## 11. 备选方案：用 MSVC 编译（若机器已装 Visual Studio 2022）

1. 装 Qt6 的 msvc 版（msvc2019_64 与 VS2022 二进制兼容）：
   ```bat
   aqt install-qt windows desktop 6.7.3 win64_msvc2019_64 -O C:\Qt -m qt5compat qtmultimedia
   ```
2. 打开 **"x64 Native Tools Command Prompt for VS 2022"**，进入源码目录。
3. 配置（同样需补 ZLIB 与 MediaInfoDLL/ZenLib）：
   `cmake -G Ninja -DCMAKE_PREFIX_PATH=C:\Qt\6.7.3\msvc2019_64\lib\cmake -DDISABLE_UPDATER=ON -B build .`
4. 编译：`cmake --build build`
5. 部署：`C:\Qt\6.7.3\msvc2019_64\bin\windeployqt.exe build\MediaElch.exe --release`（并手动补 `libquazip1-qt6.dll`）。
6. 注意：分发给他人时需附带 **Visual C++ Redistributable**。

---

## 12. 代码入口速览（试用后想加功能）

目标：复刻 tMM 部分功能 + 增量开发。MediaElch 是比 tMM 更适合的基座（C++/Qt6、LGPL 真开源、源码可得）。主要代码位置：

- `src/scraper/` —— 刮削源（TMDb/IMDb/TVDB 等），新增豆瓣刮削从这里扩展
- `src/renamer/` —— 文件/目录重命名（token 模板）
- `src/export/` —— NFO/XML 导出（Kodi 格式）
- `src/media_center/` —— Kodi/Emby/Jellyfin 等媒体中心对接
- `src/media/MediaInfoFile.cpp` —— 调用 MediaInfo.dll 读元数据
- `CMakeLists.txt` / `src/CMakeLists.txt` —— 构建与模块挂载点
- `docs/contributing/` —— 开发约定（依赖、CI、测试、打包）

---

## 13. 环境变量 / 路径速查（实测值）

| 变量 / 路径 | 实测值 |
|---|---|
| `QT_ROOT` | `C:\Qt`（**非** `D:\Qt`） |
| Qt6 cmake 配置 | `C:\Qt\6.7.3\mingw_64\lib\cmake`（`Qt6Config.cmake` 在 `Qt6\` 子目录） |
| MinGW gcc | `C:\Qt\Tools\mingw1310_64\bin\gcc.exe`（**13.1.0**） |
| ZLIB（静态） | `C:\Qt\Tools\mingw1310_64\x86_64-w64-mingw32\{include,lib}\libz.a`（1.2.13） |
| 项目根第三方头 | `MediaElch\MediaInfoDLL\`、`MediaElch\ZenLib\` |
| 运行时 DLL | `build\MediaInfo.dll`、`build\libquazip1-qt6.dll`、`build\opengl32sw.dll` |
| 最终 exe | `build\MediaElch.exe`（12.7 MB） |

> 提示：`MediaInfoDLL/`、`ZenLib/` 会出现在 `git status` 里污染环境，建议在 `.gitignore` 增加这两行（它们只是构建必需头文件，不应提交）。
