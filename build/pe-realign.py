#!/usr/bin/env python3
"""把 PE 文件（exe/dll/node）的节重新排成按页对齐，让 Wine 能直接 mmap 它们。

Wine 加载 PE 文件时，节在文件里的偏移如果不是 4 KB 的整数倍，就没法用 mmap 映射，
只能把整个节读进每个进程自己的匿名内存。Electron 的主程序有两百多 MB，
主进程、渲染进程、网络进程、crashpad 各复制一份，白白多占约 1 GB 内存。

这里把每个节放到文件偏移等于其虚拟地址的位置（FileAlignment = SectionAlignment = 0x1000），
Wine 就能 mmap 文件本身，所有进程共享同一份页缓存。代码和数据的内容不变，只改排布：
- 数字签名（证书表）会失效，直接去掉；Wine 不校验签名
- 调试目录里的文件偏移随之更新
- 带 COFF 符号表、文件末尾有附加数据、或者已经对齐的文件，原样跳过

用法: pe-realign.py <目录或文件>...
"""
import os
import struct
import sys

PAGE = 0x1000


def round_up(n, a):
    return (n + a - 1) // a * a


def realign(path):
    """重排一个文件。返回说明文字；跳过时以 "跳过" 开头。"""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 0x40 or data[:2] != b"MZ":
        return "跳过：不是 PE 文件"
    (lfanew,) = struct.unpack_from("<I", data, 0x3C)
    if data[lfanew:lfanew + 4] != b"PE\0\0":
        return "跳过：不是 PE 文件"

    coff = lfanew + 4
    nsec, = struct.unpack_from("<H", data, coff + 2)
    sym_ptr, nsym = struct.unpack_from("<II", data, coff + 8)
    opt_size, = struct.unpack_from("<H", data, coff + 16)
    opt = coff + 20
    magic, = struct.unpack_from("<H", data, opt)
    if magic == 0x20B:
        dd_count_off, dd_off = opt + 108, opt + 112
    elif magic == 0x10B:
        dd_count_off, dd_off = opt + 92, opt + 96
    else:
        return "跳过：未知的可选头"
    sect_align, file_align = struct.unpack_from("<II", data, opt + 32)
    size_of_image, size_of_headers, _ = struct.unpack_from("<III", data, opt + 56)
    checksum_off = opt + 64
    dd_count, = struct.unpack_from("<I", data, dd_count_off)
    sec_off = opt + opt_size

    if file_align >= PAGE:
        return "跳过：已经按页对齐"
    if sect_align < PAGE:
        return "跳过：节对齐小于一页"
    if sym_ptr or nsym:
        return "跳过：带 COFF 符号表"

    sections = []
    for i in range(nsec):
        o = sec_off + 40 * i
        vsize, va, raw_size, raw_ptr = struct.unpack_from("<IIII", data, o + 8)
        sections.append({"off": o, "vsize": vsize, "va": va, "raw_size": raw_size, "raw_ptr": raw_ptr})

    def dir_entry(index):
        if index >= dd_count:
            return 0, 0
        return struct.unpack_from("<II", data, dd_off + 8 * index)

    # 证书表用的是文件偏移，不随节一起加载；签名反正会失效，去掉
    cert_ptr, cert_size = dir_entry(4)
    sections_end = max([s["raw_ptr"] + s["raw_size"] for s in sections if s["raw_size"]] + [size_of_headers])
    overlay = data[sections_end:]
    if cert_size and cert_ptr >= sections_end:
        overlay = data[sections_end:cert_ptr] + data[cert_ptr + cert_size:]
    if overlay.strip(b"\0"):
        return "跳过：文件末尾有附加数据"

    new_headers = round_up(size_of_headers, PAGE)
    ordered = sorted((s for s in sections if s["raw_size"]), key=lambda s: s["va"])
    if ordered and ordered[0]["va"] < new_headers:
        return "跳过：头部和第一个节重叠"

    def old_to_new(ptr):
        for s in sections:
            if s["raw_size"] and s["raw_ptr"] <= ptr < s["raw_ptr"] + s["raw_size"]:
                return ptr - s["raw_ptr"] + s["new_ptr"]
        return None

    for i, s in enumerate(ordered):
        limit = ordered[i + 1]["va"] if i + 1 < len(ordered) else round_up(size_of_image, PAGE)
        size = round_up(s["raw_size"], PAGE)
        if s["vsize"]:
            size = min(size, round_up(s["vsize"], PAGE))
        s["new_ptr"] = s["va"]
        s["new_size"] = min(size, limit - s["va"])
        if s["new_size"] <= 0:
            return "跳过：节的排布不合常规"

    out = bytearray(ordered[-1]["va"] + ordered[-1]["new_size"] if ordered else new_headers)
    out[:size_of_headers] = data[:size_of_headers]
    for s in ordered:
        n = min(s["raw_size"], s["new_size"])
        out[s["new_ptr"]:s["new_ptr"] + n] = data[s["raw_ptr"]:s["raw_ptr"] + n]

    for s in sections:
        ptr, size = (s["new_ptr"], s["new_size"]) if s["raw_size"] else (0, 0)
        struct.pack_into("<II", out, s["off"] + 16, size, ptr)
    struct.pack_into("<I", out, opt + 36, PAGE)
    struct.pack_into("<I", out, opt + 60, new_headers)
    if cert_size:
        struct.pack_into("<II", out, dd_off + 8 * 4, 0, 0)

    # 调试目录里每一项都记着数据的文件偏移，要改成新位置
    dbg_rva, dbg_size = dir_entry(6)
    if dbg_rva and dbg_size:
        dbg = next((s for s in ordered if s["va"] <= dbg_rva < s["va"] + s["new_size"]), None)
        if dbg is None:
            return "跳过：找不到调试目录"
        base = dbg["new_ptr"] + dbg_rva - dbg["va"]
        for k in range(dbg_size // 28):
            o = base + 28 * k + 24
            raw_ptr, = struct.unpack_from("<I", out, o)
            if not raw_ptr:
                continue
            new_ptr = old_to_new(raw_ptr)
            if new_ptr is None:
                return "跳过：调试数据不在任何节里"
            struct.pack_into("<I", out, o, new_ptr)

    # 普通程序和 DLL 的校验和不做检查，内容变了就清零
    struct.pack_into("<I", out, checksum_off, 0)

    tmp = path + ".realign"
    with open(tmp, "wb") as f:
        f.write(out)
    os.chmod(tmp, os.stat(path).st_mode)
    os.replace(tmp, path)
    return "已重排（%d KB → %d KB）" % (len(data) // 1024, len(out) // 1024)


def main(args):
    if not args:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 64
    files = []
    for a in args:
        if os.path.isdir(a):
            for root, _, names in os.walk(a):
                files += [os.path.join(root, n) for n in sorted(names)
                          if n.lower().endswith((".exe", ".dll", ".node"))]
        else:
            files.append(a)
    for path in files:
        print("%s: %s" % (path, realign(path)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
