#!/usr/bin/env python3
"""scripts/path_scan.py — 扫描 do/ 目录是否混入绝对路径（防止泄露本机路径）。

用法：python scripts/path_scan.py
命中绝对路径即退出码 1（供 CI 与提交前自检）。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DO_DIR = ROOT / "do"

PATTERNS = [
    r"/Users/[A-Za-z0-9_-]+/",
    r"[A-Za-z]:\\\\",
]


def main() -> int:
    if not DO_DIR.is_dir():
        print("✓ 无 do/ 目录，跳过")
        return 0
    hits = []
    for p in sorted(DO_DIR.glob("*.do")):
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
            for pat in PATTERNS:
                if re.search(pat, line):
                    hits.append(f"  {p.name}:{i}: {line.strip()[:60]}")
    if hits:
        print("⚠️ 检测到绝对路径（可能泄露本机信息），请脱敏：")
        print("\n".join(hits))
        return 1
    print("✓ do/ 无绝对路径")
    return 0


if __name__ == "__main__":
    sys.exit(main())
