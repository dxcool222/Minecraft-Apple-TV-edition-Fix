#!/usr/bin/env python3
"""
Insert a single LC_LOAD_DYLIB command into a thin 64-bit Mach-O.
Targets the minecraftappletv arm64 binary.

Usage: inject_dylib.py <mach-o> <dylib_install_name>

Idempotent: if a load command already references the same name, exits 0.
"""

import os, sys, struct

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_REQ_DYLD = 0x80000000

# Load commands that may carry the code-signature offset, so we know which
# ones to leave alone.
LC_CODE_SIGNATURE = 0x1D
LC_SEGMENT_64 = 0x19


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: inject_dylib.py <macho> <install_name>\n")
        sys.exit(2)

    path, name = sys.argv[1], sys.argv[2]
    with open(path, "rb") as f:
        data = bytearray(f.read())

    magic, = struct.unpack_from("<I", data, 0)
    if magic != MH_MAGIC_64:
        sys.stderr.write(f"not a thin 64-bit Mach-O (magic {magic:#x})\n")
        sys.exit(1)

    # mach_header_64 layout: magic, cputype, cpusubtype, filetype, ncmds,
    # sizeofcmds, flags, reserved -- 32 bytes.
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    header_end = 32
    lc_start = header_end
    lc_end = lc_start + sizeofcmds

    # Pre-scan: skip if the dylib is already referenced.
    off = lc_start
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_LOAD_DYLIB:
            name_off, = struct.unpack_from("<I", data, off + 8)
            existing = bytes(data[off + name_off : off + cmdsize]).split(b"\x00", 1)[0]
            if existing == name.encode():
                print(f"already injected: {name}")
                return 0
        off += cmdsize

    # Build the new command. dylib_command layout:
    #   uint32 cmd; uint32 cmdsize;
    #   uint32 name.offset; uint32 timestamp;
    #   uint32 current_version; uint32 compatibility_version;
    #   [name bytes, NUL, pad to 8]
    name_bytes = name.encode() + b"\x00"
    header_size = 24
    cmdsize = header_size + len(name_bytes)
    pad = (-cmdsize) & 7  # round up to multiple of 8
    cmdsize += pad
    new_cmd = struct.pack(
        "<IIIIII",
        LC_LOAD_DYLIB,
        cmdsize,
        header_size,    # name offset
        2,              # timestamp (non-zero, matches what ld writes)
        0x00010000,     # current_version 1.0.0
        0x00010000,     # compatibility_version 1.0.0
    ) + name_bytes + (b"\x00" * pad)

    # Find where the first segment's file data starts. We can only grow
    # sizeofcmds if there's enough zero padding between the load commands
    # and the first byte that's actually referenced by a segment.
    first_segment_fileoff = None
    off = lc_start
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            # segment_command_64: cmd, cmdsize, name[16], vmaddr, vmsize,
            # fileoff, filesize, ...
            seg_fileoff, = struct.unpack_from("<Q", data, off + 32)
            seg_filesize, = struct.unpack_from("<Q", data, off + 40)
            if seg_filesize > 0:
                if first_segment_fileoff is None or seg_fileoff < first_segment_fileoff:
                    first_segment_fileoff = seg_fileoff
        off += cs

    if first_segment_fileoff is None:
        sys.stderr.write("no segments with file data; cannot determine slack\n")
        sys.exit(1)

    free = first_segment_fileoff - lc_end
    if free < len(new_cmd):
        sys.stderr.write(
            f"not enough header padding: have {free} bytes, need {len(new_cmd)}\n"
        )
        sys.exit(1)

    # Confirm slack region is actually zero before clobbering.
    if any(b != 0 for b in data[lc_end : lc_end + len(new_cmd)]):
        sys.stderr.write("header padding is non-zero; refusing to overwrite\n")
        sys.exit(1)

    # Write the new command into the padding region.
    data[lc_end : lc_end + len(new_cmd)] = new_cmd

    # Update ncmds and sizeofcmds in the header.
    new_ncmds = ncmds + 1
    new_sizeofcmds = sizeofcmds + len(new_cmd)
    struct.pack_into("<II", data, 16, new_ncmds, new_sizeofcmds)

    with open(path, "wb") as f:
        f.write(data)

    print(f"injected: {name} (cmdsize={len(new_cmd)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
