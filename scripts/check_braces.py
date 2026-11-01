#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Swift 括号 sanity（参数化，与 check_swift_braces.py 同一实现，保留旧入口名）。"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_swift_braces as base

if __name__ == "__main__":
    raise SystemExit(base.main())
