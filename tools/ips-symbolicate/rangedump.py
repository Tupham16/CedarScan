import sys, bisect
from macho import MachO
from dwarfline import LineTable, SymTab

LOAD = 0x100000000

dsym = sys.argv[1]
targets = [int(x, 0) for x in sys.argv[2:]]

m = MachO(dsym)
lt = LineTable(m)
st = SymTab(m)

for off in targets:
    addr = LOAD + off
    name, delta = st.lookup(addr)
    i = bisect.bisect_right(st.addrs, addr) - 1
    fstart = st.addrs[i]
    fend = st.addrs[i+1] if i+1 < len(st.addrs) else fstart + 0x2000
    print('=' * 100)
    print('addr 0x%x  = %s + %d   [func 0x%x .. 0x%x]' % (addr, name, delta, fstart, fend))
    lo = bisect.bisect_left(lt.addrs, fstart)
    hi = bisect.bisect_left(lt.addrs, fend)
    for r in lt.rows[lo:hi]:
        mark = '  <<<< PC' if r[0] <= addr and (lt.rows[lt.rows.index(r)+1][0] > addr if lt.rows.index(r)+1 < len(lt.rows) else True) else ''
        f = r[1]
        if 'CedarScan/Sources' in f:
            f = 'Sources' + f.split('CedarScan/Sources', 1)[1]
        print('   +%-6d 0x%x  %s:%d:%d %s%s' % (r[0]-fstart, r[0], f, r[2], r[3],
                                                'END' if r[4] else '', mark))
    print()
