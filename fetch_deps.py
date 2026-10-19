#!/usr/bin/env python3
"""Fetch MediaElch Windows build dependencies that are NOT bundled in the repo.

Downloads into the packaging_win directory (passed as argv[1]):
  - MediaInfo_DLL_24.06_Windows_x64_WithoutInstaller.7z (only if missing or broken)
  - 7zr.exe (only if missing; needed because py7zr cannot handle BCJ2)

Returns exit code 0 on success, 1 on any download failure.
This script is intentionally a standalone file so the batch wrapper does not
need to embed python one-liners with parentheses inside ( ) blocks, which makes
cmd.exe miscount parentheses and break control flow.
"""
import os
import sys
import urllib.request

MEDIAINFO_URL = (
    "https://mediaarea.net/download/binary/libmediainfo0/24.06/"
    "MediaInfo_DLL_24.06_Windows_x64_WithoutInstaller.7z"
)
SEVENZIP_URL = "https://7-zip.org/a/7zr.exe"
UA = {"User-Agent": "MediaElch-Build"}
MIN_ARCHIVE_BYTES = 1_000_000


def fetch(url, dest):
    req = urllib.request.Request(url, headers=UA)
    data = urllib.request.urlopen(req, timeout=300).read()
    with open(dest, "wb") as fh:
        fh.write(data)
    return len(data)


def main():
    if len(sys.argv) < 2:
        print("usage: fetch_deps.py <pkg_dir>")
        return 2
    pkg = sys.argv[1]
    os.makedirs(pkg, exist_ok=True)

    arc = os.path.join(pkg, "MediaInfoDLL.7z")
    if (not os.path.exists(arc)) or (os.path.getsize(arc) < MIN_ARCHIVE_BYTES):
        print("Downloading MediaInfo DLL 24.06 ...")
        try:
            size = fetch(MEDIAINFO_URL, arc)
        except Exception as exc:  # noqa: BLE001
            print("FAIL download MediaInfoDLL.7z:", exc)
            return 1
        if size < MIN_ARCHIVE_BYTES:
            print("FAIL downloaded MediaInfoDLL.7z too small:", size)
            return 1
        print("downloaded", arc, size, "bytes")
    else:
        print("MediaInfoDLL.7z already valid, skip")

    z7 = os.path.join(pkg, "7zr.exe")
    if not os.path.exists(z7):
        print("Downloading 7zr.exe ...")
        try:
            fetch(SEVENZIP_URL, z7)
        except Exception as exc:  # noqa: BLE001
            print("FAIL download 7zr.exe:", exc)
            return 1
        print("downloaded", z7)
    else:
        print("7zr.exe already present, skip")

    return 0


if __name__ == "__main__":
    sys.exit(main())
