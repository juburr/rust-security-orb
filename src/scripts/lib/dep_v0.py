"""Reads the dependency list cargo auditable embeds in an ELF binary.

cargo auditable stores it in a section named .dep-v0: a zlib stream (RFC
1950) whose content is JSON. This prints that JSON exactly as it is stored,
as rust-audit-info does, so the two can be compared byte for byte, without
rust-audit-info, which has to be built from source with a Rust toolchain.
The caller checks the JSON's shape.

It reads the ELF section headers itself, 32- and 64-bit and either byte
order, so it reads a binary built for any architecture, and needs nothing but
Python 3's standard library. The limits are rust-audit-info's: a binary of 1
GiB at most, and a dependency list of 8 MiB.

Usage: python3 -I dep_v0.py BINARY (or python3 -I -c "$PROGRAM" BINARY)

Exit codes: 0, with the JSON on stdout; 1 when the binary has no .dep-v0
section, or it doesn't decode; 2 when the binary can't be read; 3 when it
isn't an ELF file, which this decoder doesn't read (rust-audit-info also
reads PE, Mach-O and WebAssembly).
"""

import struct
import sys
import zlib

INPUT_LIMIT = 1024 * 1024 * 1024
OUTPUT_LIMIT = 8 * 1024 * 1024
SHT_NOBITS = 8
SHF_COMPRESSED = 0x800
SHN_XINDEX = 0xFFFF


class NoData(Exception):
    """The binary carries no dependency list that decodes."""


class NotElf(Exception):
    """The file is not an ELF file."""


def dep_v0_section(data):
    """Returns the bytes of the binary's one .dep-v0 section."""
    if len(data) < 16 or data[:4] != b"\x7fELF":
        raise NotElf()
    elf_class, encoding = data[4], data[5]
    if elf_class not in (1, 2) or encoding not in (1, 2):
        raise NoData("its ELF header names an unknown class or byte order")
    order = "<" if encoding == 1 else ">"
    if elf_class == 2:
        header = struct.Struct(order + "16xHHIQQQIHHHHHH")
        entry = struct.Struct(order + "IIQQQQIIQQ")
    else:
        header = struct.Struct(order + "16xHHIIIIIHHHHHH")
        entry = struct.Struct(order + "IIIIIIIIII")
    if len(data) < header.size:
        raise NoData("its ELF header is cut short")
    fields = header.unpack_from(data)
    shoff, shentsize, shnum, shstrndx = fields[5], fields[10], fields[11], fields[12]
    if shoff == 0:
        raise NoData("it has no section headers (stripped with --strip-section-headers?)")
    if shentsize < entry.size:
        raise NoData("its section headers are smaller than the ELF format's")

    def section(index):
        # name, type, flags, address, offset, size, link, info, alignment,
        # entry size
        offset = shoff + index * shentsize
        if offset + entry.size > len(data):
            raise NoData("its section headers run past the end of the file")
        return entry.unpack_from(data, offset)

    # With more sections than the header can count, section 0 holds the
    # count (sh_size) and the name table's index (sh_link).
    if shnum == 0:
        shnum = section(0)[5]
    if shstrndx == SHN_XINDEX:
        shstrndx = section(0)[6]
    if shnum * shentsize > len(data) or shstrndx >= shnum:
        raise NoData("its section headers don't fit in the file")
    names = section(shstrndx)
    if names[4] + names[5] > len(data):
        raise NoData("its section name table runs past the end of the file")
    names = data[names[4]:names[4] + names[5]]
    found = []
    for index in range(shnum):
        fields = section(index)
        end = names.find(b"\0", fields[0])
        if fields[0] < len(names) and names[fields[0]:end if end >= 0 else len(names)] == b".dep-v0":
            found.append(fields)
    if not found:
        raise NoData("it has no .dep-v0 section: build it with cargo auditable, and strip it with GNU strip, not llvm-strip")
    if len(found) > 1:
        raise NoData("it has %d .dep-v0 sections" % len(found))
    fields = found[0]
    if fields[1] == SHT_NOBITS:
        raise NoData("its .dep-v0 section holds no data")
    if fields[2] & SHF_COMPRESSED:
        raise NoData("its .dep-v0 section was compressed by the linker")
    offset, size = fields[4], fields[5]
    if offset + size > len(data):
        raise NoData("its .dep-v0 section runs past the end of the file")
    return data[offset:offset + size]


def inflate(stream):
    """Returns the JSON the zlib stream holds, checked as rust-audit-info does."""
    if len(stream) > OUTPUT_LIMIT:
        raise NoData("its .dep-v0 section is larger than 8 MiB")
    inflater = zlib.decompressobj()
    try:
        text = inflater.decompress(stream, OUTPUT_LIMIT + 1)
    except zlib.error as error:
        raise NoData("its .dep-v0 section is not a zlib stream that decodes: %s" % error)
    if len(text) > OUTPUT_LIMIT or inflater.unconsumed_tail:
        raise NoData("its .dep-v0 section decompresses to more than 8 MiB")
    if not inflater.eof:
        raise NoData("its .dep-v0 section's zlib stream is cut short")
    if inflater.unused_data.strip(b"\0"):
        raise NoData("its .dep-v0 section has data after its zlib stream")
    try:
        text.decode("utf-8")
    except UnicodeDecodeError:
        raise NoData("its dependency list is not UTF-8 text")
    return text


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("Usage: python3 -I dep_v0.py BINARY\n")
        return 2
    try:
        with open(sys.argv[1], "rb") as binary:
            data = binary.read(INPUT_LIMIT + 1)
    except OSError as error:
        sys.stderr.write("cannot read %s: %s\n" % (sys.argv[1], error.strerror))
        return 2
    if len(data) > INPUT_LIMIT:
        sys.stderr.write("%s is larger than 1 GiB\n" % sys.argv[1])
        return 2
    try:
        text = inflate(dep_v0_section(data))
    except NotElf:
        sys.stderr.write("%s is not an ELF file, and the native decoder reads only ELF; use decoder: rust-audit-info\n" % sys.argv[1])
        return 3
    except NoData as reason:
        sys.stderr.write("No usable audit data: %s\n" % reason)
        return 1
    sys.stdout.buffer.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
