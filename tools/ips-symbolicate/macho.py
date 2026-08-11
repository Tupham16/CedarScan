import struct, sys, uuid

MH_MAGIC_64 = 0xfeedfacf
MH_CIGAM_64 = 0xcffaedfe
FAT_MAGIC = 0xcafebabe
FAT_CIGAM = 0xbebafeca

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_UUID = 0x1b

class MachO:
    def __init__(self, path, want_arch=None):
        self.path = path
        with open(path, 'rb') as f:
            self.data = f.read()
        d = self.data
        magic = struct.unpack_from('>I', d, 0)[0]
        self.slices = []
        if magic in (FAT_MAGIC, FAT_CIGAM):
            nfat = struct.unpack_from('>I', d, 4)[0]
            for i in range(nfat):
                cputype, cpusub, off, size, align = struct.unpack_from('>iiIII', d, 8 + i*20)
                self.slices.append((cputype, cpusub, off, size))
        else:
            self.slices.append((None, None, 0, len(d)))
        # pick slice
        self.base = self.slices[0][2]
        if want_arch is not None:
            for cputype, cpusub, off, size in self.slices:
                if cputype == want_arch:
                    self.base = off
                    break
        self._parse(self.base)

    def _parse(self, base):
        d = self.data
        magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, res = struct.unpack_from('<IiiIIIII', d, base)
        assert magic == MH_MAGIC_64, hex(magic)
        self.cputype = cputype
        self.cpusubtype = cpusubtype
        self.uuid = None
        self.sections = {}   # (seg,sect) -> (addr, offset, size)
        self.segments = {}
        self.symtab = None
        off = base + 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from('<II', d, off)
            if cmd == LC_UUID:
                self.uuid = uuid.UUID(bytes=d[off+8:off+24])
            elif cmd == LC_SEGMENT_64:
                segname = d[off+8:off+24].rstrip(b'\x00').decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off+24)
                nsects = struct.unpack_from('<I', d, off+64)[0]
                self.segments[segname] = (vmaddr, vmsize, fileoff, filesize)
                so = off + 72
                for _s in range(nsects):
                    sectname = d[so:so+16].rstrip(b'\x00').decode()
                    sgn = d[so+16:so+32].rstrip(b'\x00').decode()
                    addr, size = struct.unpack_from('<QQ', d, so+32)
                    offset = struct.unpack_from('<I', d, so+48)[0]
                    self.sections[(sgn, sectname)] = (addr, offset, size)
                    so += 80
            elif cmd == LC_SYMTAB:
                symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', d, off+8)
                self.symtab = (symoff, nsyms, stroff, strsize)
            off += cmdsize

    def section_data(self, seg, sect):
        key = (seg, sect)
        if key not in self.sections:
            return None
        addr, offset, size = self.sections[key]
        return self.data[self.base + offset: self.base + offset + size]

    def symbols(self):
        if not self.symtab:
            return []
        symoff, nsyms, stroff, strsize = self.symtab
        d = self.data
        out = []
        strbase = self.base + stroff
        for i in range(nsyms):
            o = self.base + symoff + i*16
            n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from('<IBBHQ', d, o)
            end = d.index(b'\x00', strbase + n_strx)
            name = d[strbase+n_strx:end].decode('utf-8', 'replace')
            out.append((name, n_type, n_sect, n_desc, n_value))
        return out

if __name__ == '__main__':
    m = MachO(sys.argv[1])
    print('slices', m.slices)
    print('uuid', m.uuid)
    print('cputype', m.cputype, 'subtype', m.cpusubtype)
    for k, v in sorted(m.sections.items()):
        print(k, hex(v[0]), hex(v[1]), v[2])
    print('symtab', m.symtab)
