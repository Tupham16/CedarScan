import struct, sys, bisect
from macho import MachO

def uleb(d, o):
    r = 0; s = 0
    while True:
        b = d[o]; o += 1
        r |= (b & 0x7f) << s
        if not (b & 0x80): break
        s += 7
    return r, o

def sleb(d, o):
    r = 0; s = 0
    while True:
        b = d[o]; o += 1
        r |= (b & 0x7f) << s
        s += 7
        if not (b & 0x80):
            if b & 0x40:
                r -= (1 << s)
            break
    return r, o

def cstr(d, o):
    e = d.index(b'\x00', o)
    return d[o:e].decode('utf-8', 'replace'), e + 1

# DW_LNCT
DW_LNCT_path = 1
DW_LNCT_directory_index = 2

# DW_FORM
def read_form(d, o, form, offset_size, debug_str, debug_line_str):
    if form == 0x08:  # string
        return cstr(d, o)
    if form == 0x0e:  # strp
        v = int.from_bytes(d[o:o+offset_size], 'little'); o += offset_size
        e = debug_str.index(b'\x00', v)
        return debug_str[v:e].decode('utf-8', 'replace'), o
    if form == 0x1f:  # line_strp
        v = int.from_bytes(d[o:o+offset_size], 'little'); o += offset_size
        e = debug_line_str.index(b'\x00', v)
        return debug_line_str[v:e].decode('utf-8', 'replace'), o
    if form == 0x0b:  # data1
        return d[o], o+1
    if form == 0x05:  # data2
        return struct.unpack_from('<H', d, o)[0], o+2
    if form == 0x06:  # data4
        return struct.unpack_from('<I', d, o)[0], o+4
    if form == 0x07:  # data8
        return struct.unpack_from('<Q', d, o)[0], o+8
    if form == 0x0f:  # udata
        return uleb(d, o)
    if form == 0x1e:  # data16 (MD5)
        return d[o:o+16], o+16
    raise NotImplementedError('form 0x%x' % form)


class LineTable:
    """Parses the whole __debug_line section into address-sorted rows."""
    def __init__(self, macho):
        self.rows = []  # (address, file_str, line, col, end_seq)
        dl = macho.section_data('__DWARF', '__debug_line')
        dstr = macho.section_data('__DWARF', '__debug_str') or b''
        dlstr = macho.section_data('__DWARF', '__debug_line_str') or b''
        o = 0
        n = len(dl)
        while o < n:
            o = self._one_unit(dl, o, dstr, dlstr)
        self.rows.sort(key=lambda r: r[0])
        self.addrs = [r[0] for r in self.rows]

    def _one_unit(self, d, o, dstr, dlstr):
        unit_start = o
        ulen = struct.unpack_from('<I', d, o)[0]; o += 4
        offset_size = 4
        if ulen == 0xffffffff:
            ulen = struct.unpack_from('<Q', d, o)[0]; o += 8
            offset_size = 8
        unit_end = o + ulen
        version = struct.unpack_from('<H', d, o)[0]; o += 2
        if version >= 5:
            addr_size = d[o]; o += 1
            seg_sel = d[o]; o += 1
        header_length = int.from_bytes(d[o:o+offset_size], 'little'); o += offset_size
        prog_start = o + header_length
        min_inst_len = d[o]; o += 1
        max_ops = 1
        if version >= 4:
            max_ops = d[o]; o += 1
        default_is_stmt = d[o]; o += 1
        line_base = struct.unpack_from('<b', d, o)[0]; o += 1
        line_range = d[o]; o += 1
        opcode_base = d[o]; o += 1
        std_lens = []
        for i in range(opcode_base - 1):
            std_lens.append(d[o]); o += 1

        include_dirs = []
        file_names = []  # (name, dir_index)
        if version >= 5:
            # directory table
            dfc = d[o]; o += 1
            dformats = []
            for _ in range(dfc):
                ct, o = uleb(d, o)
                fm, o = uleb(d, o)
                dformats.append((ct, fm))
            dcount, o = uleb(d, o)
            for _ in range(dcount):
                path = None
                for ct, fm in dformats:
                    v, o = read_form(d, o, fm, offset_size, dstr, dlstr)
                    if ct == DW_LNCT_path:
                        path = v
                include_dirs.append(path)
            ffc = d[o]; o += 1
            fformats = []
            for _ in range(ffc):
                ct, o = uleb(d, o)
                fm, o = uleb(d, o)
                fformats.append((ct, fm))
            fcount, o = uleb(d, o)
            for _ in range(fcount):
                path = None; di = 0
                for ct, fm in fformats:
                    v, o = read_form(d, o, fm, offset_size, dstr, dlstr)
                    if ct == DW_LNCT_path: path = v
                    elif ct == DW_LNCT_directory_index: di = v
                file_names.append((path, di))
        else:
            include_dirs.append(None)  # index 0 = comp dir
            while True:
                s, o = cstr(d, o)
                if s == '': break
                include_dirs.append(s)
            file_names.append((None, 0))  # index 0 unused in v<5
            while True:
                s, o = cstr(d, o)
                if s == '': break
                di, o = uleb(d, o)
                _mt, o = uleb(d, o)
                _len, o = uleb(d, o)
                file_names.append((s, di))

        def filestr(idx):
            if idx < 0 or idx >= len(file_names):
                return '<file#%d>' % idx
            nm, di = file_names[idx]
            if nm is None:
                return '<file#%d>' % idx
            if nm.startswith('/') or (len(nm) > 1 and nm[1] == ':'):
                return nm
            dpart = include_dirs[di] if 0 <= di < len(include_dirs) else None
            return (dpart + '/' + nm) if dpart else nm

        # run program
        o = prog_start
        addr = 0; file = 1; line = 1; col = 0; is_stmt = default_is_stmt
        op_index = 0
        def reset():
            nonlocal addr, file, line, col, is_stmt, op_index
            addr = 0; file = 1 if version < 5 else 1; line = 1; col = 0
            is_stmt = default_is_stmt; op_index = 0
        if version >= 5:
            file = 1
        while o < unit_end:
            opc = d[o]; o += 1
            if opc >= opcode_base:
                adj = opc - opcode_base
                addr += (adj // line_range) * min_inst_len
                line += line_base + (adj % line_range)
                self.rows.append((addr, filestr(file), line, col, False))
            elif opc == 0:
                length, o = uleb(d, o)
                sub = d[o]
                if sub == 0x01:  # end_sequence
                    self.rows.append((addr, filestr(file), line, col, True))
                    reset()
                elif sub == 0x02:  # set_address
                    addr = struct.unpack_from('<Q', d, o+1)[0]
                elif sub == 0x03:  # define_file
                    pass
                o += length
            else:
                if opc == 0x01:  # copy
                    self.rows.append((addr, filestr(file), line, col, False))
                elif opc == 0x02:
                    v, o = uleb(d, o); addr += v * min_inst_len
                elif opc == 0x03:
                    v, o = sleb(d, o); line += v
                elif opc == 0x04:
                    file, o = uleb(d, o)
                elif opc == 0x05:
                    col, o = uleb(d, o)
                elif opc == 0x06:
                    is_stmt = not is_stmt
                elif opc == 0x07:
                    pass
                elif opc == 0x08:
                    adj = 255 - opcode_base
                    addr += (adj // line_range) * min_inst_len
                elif opc == 0x09:
                    v = struct.unpack_from('<H', d, o)[0]; o += 2; addr += v
                elif opc == 0x0a or opc == 0x0b:
                    pass
                elif opc == 0x0c:
                    v, o = uleb(d, o)
                else:
                    for _ in range(std_lens[opc-1]):
                        _v, o = uleb(d, o)
        return unit_end

    def lookup(self, address):
        i = bisect.bisect_right(self.addrs, address) - 1
        if i < 0:
            return None
        row = self.rows[i]
        if row[4]:  # end_sequence: address is past the end
            if row[0] == address:
                pass
            return None if row[0] < address else None
        return row


class SymTab:
    def __init__(self, macho):
        syms = []
        for name, n_type, n_sect, n_desc, n_value in macho.symbols():
            stab = n_type & 0xe0
            if stab:
                if n_type == 0x24 and name:  # N_FUN with name
                    syms.append((n_value, name))
                continue
            if (n_type & 0x0e) == 0x0e and n_value:  # N_SECT
                syms.append((n_value, name))
        # dedupe/sort
        syms.sort()
        self.addrs = [s[0] for s in syms]
        self.names = [s[1] for s in syms]

    def lookup(self, address):
        i = bisect.bisect_right(self.addrs, address) - 1
        if i < 0:
            return None, None
        return self.names[i], address - self.addrs[i]
