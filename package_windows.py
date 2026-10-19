#!/usr/bin/env python3
"""把 build/ 选择性打包成自包含可运行子集 zip（剔除编译垃圾）。

规则：
  - 保留 exe / dll / qm / conf 以及所有 Qt 插件子目录
    （platforms, imageformats, styles, sqldrivers, tls, translations ...）
  - 剔除编译中间体：*.obj, *.o, CMakeFiles, *.dir, build.ninja, CMakeCache.txt 等
用法：
  python package_windows.py            # 默认版本 2.12.1
  MEDIAELCH_VER=2.12.1 python package_windows.py
"""
import os
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(ROOT, "build")
VER = os.environ.get("MEDIAELCH_VER", "2.12.1")
OUT = os.path.join(ROOT, "dist", f"MediaElch-{VER}-windows-x64.zip")

PLUGIN_DIRS = {
    "platforms", "imageformats", "styles", "sqldrivers", "tls",
    "networkinformation", "iconengines", "virtualkeyboard", "generic",
    "accessible", "scenegraph", "qmltooling", "printsupport", "audio",
    "mediaservice", "playlistformats", "bearer", "platformthemes",
}
SKIP_NAMES = {
    "CMakeCache.txt", ".ninja_deps", ".ninja_log", "cmake_install.cmake",
    "Makefile", "Progress", "rules.ninja", "install_manifest.txt",
    "CTestTestfile.cmake",
}
ROOT_KEEP_EXT = {".exe", ".dll", ".qm", ".conf"}


def main() -> None:
    if not os.path.isdir(BUILD):
        raise SystemExit(f"找不到 build/ 目录：{BUILD}\n请先运行 build_windows.bat 完成编译。")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    count = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for r, dirs, files in os.walk(BUILD):
            # 跳过编译中间目录
            dirs[:] = [d for d in dirs if d != "CMakeFiles" and not d.endswith(".dir")]
            rel_r = os.path.relpath(r, BUILD)
            parts = rel_r.split(os.sep)
            in_plugin = any(p in PLUGIN_DIRS for p in parts)
            for fn in files:
                ext = os.path.splitext(fn)[1].lower()
                if fn in SKIP_NAMES or ext in (".obj", ".o"):
                    continue
                if (ext in (".exe", ".dll", ".qm")
                        or in_plugin
                        or (rel_r == "." and ext in ROOT_KEEP_EXT)):
                    rel = os.path.relpath(os.path.join(r, fn), BUILD)
                    z.write(os.path.join(r, fn), rel)
                    count += 1
    size_mb = os.path.getsize(OUT) / 1_048_576
    print(f"PACKED {count} files -> {OUT} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
