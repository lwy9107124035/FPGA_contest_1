# -*- coding: utf-8 -*-
"""Get physical LCN of each BMP on D: and simulate RTL sector scan."""
import os
import struct
import ctypes
from ctypes import wintypes

k32 = ctypes.windll.kernel32

# FSCTL_GET_RETRIEVAL_POINTERS = 0x0009003B
FSCTL_GET_RETRIEVAL_POINTERS = 0x0009003B
FSCTL_GET_VOLUME_BITMAP = 0x000900CF  # skip
FILE_FLAG_BACKUP_SEMANTICS = 0x02000000


class RETRIEVAL_POINTERS_BUFFER(ctypes.Structure):
    _fields_ = [
        ("ExtentCount", wintypes.DWORD),
        ("StartingVcn", ctypes.c_longlong),
        ("Extents", ctypes.c_ulonglong * 1),  # flexible; we over-read buffer
    ]


def get_extents(path, max_extents=64):
    h = k32.CreateFileW(
        path,
        0,  # no access needed? need some for FSCTL
        7,  # read/write/share
        None,
        3,
        FILE_FLAG_BACKUP_SEMANTICS,
        None,
    )
    if h == -1 or h == wintypes.HANDLE(-1).value:
        raise ctypes.WinError()
    try:
        # buffer: header 16 bytes (DWORD + pad + LONGLONG VCN) + extents * 8
        # RETRIEVAL_POINTERS_BUFFER: DWORD ExtentCount; LARGE_INTEGER StartingVcn; followed by extents
        # Actually: DWORD ExtentCount; LARGE_INTEGER StartingVcn; RPB_EXTENT Extents[1];
        # RPB_EXTENT: LARGE_INTEGER Lcn; LARGE_INTEGER NextVcn;
        buf_size = 16 + max_extents * 16
        buf = ctypes.create_string_buffer(buf_size)
        br = wintypes.DWORD()
        ok = k32.DeviceIoControl(
            h,
            FSCTL_GET_RETRIEVAL_POINTERS,
            None,
            0,
            buf,
            buf_size,
            ctypes.byref(br),
            None,
        )
        if not ok:
            raise ctypes.WinError()
        data = buf.raw[: br.value]
        extent_count = struct.unpack_from("<I", data, 0)[0]
        starting_vcn = struct.unpack_from("<Q", data, 8)[0]
        extents = []
        off = 16
        for i in range(extent_count):
            lcn = struct.unpack_from("<Q", data, off)[0]
            next_vcn = struct.unpack_from("<Q", data, off + 8)[0]
            extents.append((lcn, next_vcn))
            off += 16
        return starting_vcn, extents
    finally:
        k32.CloseHandle(h)


def main():
    # BPB from filesystem read of boot - open \\.\D: with python
    # We already know from earlier run:
    # data_start_sec=65536, cluster=4096, bps=512, spc=8
    bps = 512
    spc = 8
    data_start_sec = 65536
    cluster_bytes = bps * spc
    # LCN is cluster index from start of data area (usually LCN 0 = first data cluster)
    # On Windows FSCTL, LCN is absolute from start of volume's data (cluster 2 on disk = LCN 0)?
    # Actually Windows LCN is from the start of the volume in clusters (including reserved),
    # OR from data start? Documented as: LCN is the cluster number relative to the beginning of the volume.
    # For FAT32, cluster 2 is first data cluster. LCN in FSCTL is often the same as FAT cluster number.
    # Empirical: sec = LCN * spc  if LCN is absolute from volume start in clusters...
    # Volume start sector 0 = cluster 0 conceptually for BIOS; FAT cluster N starts at sector data_start+(N-2)*spc
    # Windows LCN: "starting LCN of the extent" - for FAT32 typically equals FAT cluster number.

    files = sorted(
        os.path.join("D:\\", f)
        for f in os.listdir("D:\\")
        if f.lower().endswith(".bmp")
    )
    print("files:", len(files))

    layout = []  # (first_sector, name, size, n_clusters)
    for path in files:
        name = os.path.basename(path)
        size = os.path.getsize(path)
        try:
            vcn, extents = get_extents(path)
        except OSError as e:
            print(name, "FSCTL fail", e)
            continue
        # convert extents to sector list
        nclus = (size + cluster_bytes - 1) // cluster_bytes
        # Build map: file byte offset -> sector
        # For RTL: first sector of file
        if not extents:
            print(name, "no extents")
            continue
        first_lcn = extents[0][0]
        # Assume LCN is FAT cluster number (2 = first data)
        if first_lcn >= 2:
            first_sec = data_start_sec + (first_lcn - 2) * spc
        else:
            # LCN is 0-based from data start
            first_sec = data_start_sec + first_lcn * spc
        layout.append((first_sec, name, size, nclus, first_lcn, extents))
        print(
            "%s size=%d first_lcn=%d first_sec=%d extents=%d nclus=%d"
            % (name, size, first_lcn, first_sec, len(extents), nclus)
        )

    layout.sort()
    print("\n--- layout by sector ---")
    for first_sec, name, size, nclus, lcn, extents in layout:
        sec_count = (size + 511) // 512
        print(
            "%s sec=%d..%d (%d sec) contiguous_extents=%d"
            % (name, first_sec, first_sec + sec_count - 1, sec_count, len(extents))
        )

    # Simulate RTL scan: need ability to read sectors. Use \\.\D:
    print("\nopening volume...")
    vol = open(r"\\.\D:", "rb", buffering=0)
    scan_max = 131071
    scan_sector = 0
    found = 0
    hits = []
    steps = 0
    while scan_sector <= scan_max and found < 32 and steps < 250000:
        steps += 1
        try:
            vol.seek(scan_sector * 512)
            sec = vol.read(512)
        except OSError as e:
            print("read fail at", scan_sector, e)
            break
        if len(sec) < 54:
            break
        if sec[0:2] == b"BM":
            w = struct.unpack_from("<i", sec, 18)[0]
            hgt = struct.unpack_from("<i", sec, 22)[0]
            bpp = struct.unpack_from("<H", sec, 28)[0]
            comp = struct.unpack_from("<I", sec, 30)[0]
            fsize = struct.unpack_from("<I", sec, 2)[0]
            w16 = w & 0xFFFF
            h16 = hgt & 0xFFFF
            mr_ok = (
                320 <= w16 <= 1280
                and 16 <= h16 <= 1080
                and w16 <= (h16 << 2)
                and h16 <= (w16 << 2)
                and (w16 & 3) == 0
            )
            if bpp == 24 and comp == 0 and mr_ok:
                file_sectors = 1 if fsize == 0 else ((fsize + 511) >> 9)
                is_real = any(scan_sector == s for s, _, _, _, _, _ in layout)
                found += 1
                hits.append((scan_sector, is_real, w, hgt, fsize))
                print(
                    "HIT#%d %s sec=%d %dx%d fsize=%d jump->%d"
                    % (
                        found,
                        "REAL" if is_real else "FALSE",
                        scan_sector,
                        w,
                        hgt,
                        fsize,
                        scan_sector + file_sectors,
                    )
                )
                scan_sector += file_sectors
                continue
        scan_sector += 1
    vol.close()
    print("done found=%d steps=%d last=%d" % (found, steps, scan_sector))

    # If FALSE hits before REAL, show whether walk lands on real files
    real_secs = {s for s, _, _, _, _, _ in layout}
    print("\nreal file sectors:", sorted(real_secs))
    print("hit sectors:", [h[0] for h in hits])


if __name__ == "__main__":
    main()
