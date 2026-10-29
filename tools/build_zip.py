#!/usr/bin/env python3
"""把 module/ 目录打成可刷入的 Magisk / KernelSU 模块 zip。

用法:
    python tools/build_zip.py
    python tools/build_zip.py -o my_module.zip
"""
import argparse
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_DIR = os.path.join(ROOT, "module")
FIXED = [
    "module.prop",
    "post-fs-data.sh",
    "service.sh",
    "META-INF/com/google/android/update-binary",
    "META-INF/com/google/android/updater-script",
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", default=os.path.join(ROOT, "hc_cacert.zip"))
    args = ap.parse_args()

    if not os.path.isfile(os.path.join(MODULE_DIR, "module.prop")):
        print("module/module.prop 不存在", file=sys.stderr)
        return 1

    entries = [p for p in FIXED if os.path.isfile(os.path.join(MODULE_DIR, p))]
    certs_dir = os.path.join(MODULE_DIR, "certs")
    if os.path.isdir(certs_dir):
        for name in sorted(os.listdir(certs_dir)):
            if name.endswith(".0"):
                entries.append("certs/" + name)
    if not any(e.startswith("certs/") for e in entries):
        print("[warn] module/certs/ 下没有 <hash>.0 证书，模块开机时会自行跳过", file=sys.stderr)

    if os.path.exists(args.output):
        os.remove(args.output)

    with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in entries:
            z.write(os.path.join(MODULE_DIR, rel.replace("/", os.sep)), rel)

    print("built %s (%d bytes, %d files)" % (args.output, os.path.getsize(args.output), len(entries)))
    print("刷入: KernelSU / Magisk 管理器 -> 模块 -> 从本地安装 -> 重启")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
