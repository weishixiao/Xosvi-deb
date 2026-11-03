#!/usr/bin/env python3
"""校验 Mach-O 的 CodeDirectory 是否带 CS_ADHOC(0x2)。

这是报告 7.1 的根因检查：ldid 不带 -Cadhoc 时区 flags=0，Security 层
（TrollStore / 部分安装器走的 SecCodeCopySigningInformation）会判定
「无签名」，把 entitlements 读成 nil → 被重签成沙盒 App。

用法：
    python3 check-adhoc.py <macho> [<macho> ...]     # 全部通过才退出 0
"""
import struct
import sys


def _code_signature_range(data):
    """返回 (offset, size)；没有 LC_CODE_SIGNATURE 返回 None。"""
    if data[:4] != b"\xcf\xfa\xed\xfe":
        return None
    ncmds = struct.unpack("<I", data[16:20])[0]
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(data):
            return None
        cmd, size = struct.unpack("<II", data[off:off + 8])
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            return struct.unpack("<II", data[off + 8:off + 16])
        if size < 8:
            return None
        off += size
    return None


def check(path):
    """返回 (ok: bool, message: str)。"""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        return False, "%s: cannot read (%s)" % (path, e)

    rng = _code_signature_range(data)
    if not rng:
        return False, "%s: NO CODE SIGNATURE" % path
    off, size = rng
    blob = data[off:off + size]
    if len(blob) < 12:
        return False, "%s: truncated signature blob" % path

    magic, _length, count = struct.unpack(">III", blob[:12])
    if magic != 0xFADE0CC0:
        return False, "%s: bad SuperBlob magic 0x%08x" % (path, magic)

    pos = 12
    for _ in range(count):
        if pos + 8 > len(blob):
            break
        slot_type, slot_off = struct.unpack(">II", blob[pos:pos + 8])
        pos += 8
        if slot_type == 0:  # CSSLOT_CODEDIRECTORY
            if slot_off + 16 > len(blob):
                return False, "%s: CodeDirectory out of bounds" % path
            flags = struct.unpack(">I", blob[slot_off + 12:slot_off + 16])[0]
            if flags & 0x2:
                return True, "%s: OK (flags=0x%x)" % (path, flags)
            return False, "%s: CS_ADHOC NOT SET (flags=0x%x)" % (path, flags)
    return False, "%s: no CodeDirectory in SuperBlob" % path


def main(argv):
    if not argv:
        sys.stderr.write(__doc__ or "")
        return 2
    failed = 0
    for p in argv:
        ok, msg = check(p)
        print(("PASS " if ok else "FAIL ") + msg)
        if not ok:
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
