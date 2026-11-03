#!/usr/bin/env python3
"""校验 Mach-O 二进制 / .app / .ipa / .tipa 内嵌的 entitlements。

纯标准库实现（可在 macOS CI、Linux、以及设备上的 bin/python3 里跑）：
解析 LC_CODE_SIGNATURE -> CS_SuperBlob -> slot 5(entitlements) / slot 7(DER)。

用法:
  python3 verify_entitlements.py <Xosvi.app | Xosvi | X.tipa | X.ipa> [--require k1,k2,...]
退出码: 0 = 全部必需项都在；1 = 缺失（并打印明细）；2 = 解析失败。
"""
import sys, os, struct, zipfile, tempfile, shutil, plistlib, re

REQUIRED = [
    "platform-application",
    "com.apple.private.security.no-sandbox",
    "com.apple.private.security.container-manager",
    "com.apple.private.MobileContainerManager.allowed",
    "task_for_pid-allow",
    "jb.pmap_cs.custom_trust",
]

LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_ENTITLEMENTS = 0xFADE7171
CSMAGIC_DER_ENTITLEMENTS = 0xFADE7172
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA


def _thin_slices(data):
    """返回 [(offset, size)]，每个是 thin Mach-O 的片段。"""
    if len(data) < 8:
        return []
    magic = struct.unpack(">I", data[:4])[0]
    le = struct.unpack("<I", data[:4])[0]
    if le in (MH_MAGIC_64, 0xFEEDFACE):
        return [(0, len(data))]
    if magic in (FAT_MAGIC,) or struct.unpack("<I", data[:4])[0] == FAT_MAGIC:
        nfat = struct.unpack(">I", data[4:8])[0]
        out = []
        off = 8
        for _ in range(nfat):
            _cputype, _cpusub, offset, size, _align = struct.unpack(">IIIII", data[off:off + 20])
            out.append((offset, size))
            off += 20
        return out
    return []


def _cs_blob(data, off):
    """定位 LC_CODE_SIGNATURE 指向的 SuperBlob，返回 (superblob_offset, slots{type: bytes-thunk})。"""
    magic_le = struct.unpack("<I", data[off:off + 4])[0]
    little = magic_le in (MH_MAGIC_64, 0xFEEDFACE)
    end = "<" if little else ">"
    is64 = (magic_le if little else struct.unpack(">I", data[off:off + 4])[0]) == MH_MAGIC_64
    hdr = 32 if is64 else 28
    ncmds = struct.unpack(end + "I", data[off + 16:off + 20])[0]
    p = off + hdr
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack(end + "II", data[p:p + 8])
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack(end + "II", data[p + 8:p + 16])
            sb = off + dataoff
            m, ln, cnt = struct.unpack(">III", data[sb:sb + 12])
            if m != CSMAGIC_EMBEDDED_SIGNATURE:
                return None, {}
            slots = {}
            q = sb + 12
            for _i in range(cnt):
                t, o = struct.unpack(">II", data[q:q + 8])
                q += 8
                bm, bl = struct.unpack(">II", data[sb + o:sb + o + 8])
                slots[t] = (bm, data[sb + o + 8:sb + o + bl])
            return sb, slots
        if cmdsize <= 0:
            break
        p += cmdsize
    return None, {}


def parse_binary(path):
    data = open(path, "rb").read()
    res = []
    for off, _size in _thin_slices(data):
        sb, slots = _cs_blob(data, off)
        if sb is None:
            res.append({"path": path, "offset": off, "error": "no LC_CODE_SIGNATURE / bad SuperBlob"})
            continue
        ent = None
        if 5 in slots and slots[5][0] == CSMAGIC_ENTITLEMENTS:
            raw = slots[5][1]
            try:
                ent = plistlib.loads(raw)
            except Exception:
                txt = raw.decode("utf-8", "replace")
                ent = {}
                for k in re.findall(r"<key>([^<]+)</key>", txt):
                    ent[k] = "?"
        der = 7 in slots and slots[7][0] == CSMAGIC_DER_ENTITLEMENTS
        res.append({"path": path, "offset": off, "entitlements": ent, "der": der,
                    "slots": sorted(slots.keys())})
    return res


def resolve_target(target):
    """把 .app/.ipa/.tipa 归一到待检查的可执行文件列表。"""
    if os.path.isdir(target):
        apps = [target]
    elif zipfile.is_zipfile(target):
        tmp = tempfile.mkdtemp(prefix="entcheck-")
        with zipfile.ZipFile(target) as z:
            z.extractall(tmp)
        apps = [os.path.join(tmp, "Payload", n) for n in os.listdir(os.path.join(tmp, "Payload"))]
        apps = [a for a in apps if a.endswith(".app")]
    else:
        return [target], None
    bins = []
    for app in apps:
        info = os.path.join(app, "Info.plist")
        exe = "Payload"
        try:
            exe = plistlib.load(open(info, "rb")).get("CFBundleExecutable", exe)
        except Exception:
            pass
        bins.append(os.path.join(app, exe))
    return bins, None


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    target = argv[1]
    required = REQUIRED
    for i, a in enumerate(argv):
        if a == "--require" and i + 1 < len(argv):
            required = [x.strip() for x in argv[i + 1].split(",") if x.strip()]

    bins, _ = resolve_target(target)
    missing_total = []
    ok = True
    for b in bins:
        if not os.path.exists(b):
            print(f"[FAIL] {b}: 文件不存在")
            ok = False
            continue
        for r in parse_binary(b):
            name = os.path.basename(b)
            if "error" in r:
                print(f"[FAIL] {name} slice@{r['offset']}: {r['error']}")
                ok = False
                continue
            ent = r["entitlements"] or {}
            print(f"\n=== {name} slice@{r['offset']}  slots={r['slots']}  键数={len(ent)}  DER={r['der']} ===")
            for k in required:
                hit = k in ent
                print(f"  {'OK  ' if hit else 'MISS'} {k}" + (f" = {ent[k]!r}" if hit else ""))
                if not hit:
                    missing_total.append(f"{name}:{k}")
                    ok = False
            extra = [k for k in ("com.apple.private.security.no-container",
                                 "com.apple.private.security.container-required",
                                 "com.apple.private.tcc.manager",
                                 "com.apple.system-task-ports")]
            for k in extra:
                if k in ent:
                    print(f"  bonus {k} = {ent[k]!r}")
    print("\n" + ("RESULT: PASS" if ok else "RESULT: FAIL — 缺失 " + ", ".join(missing_total)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
