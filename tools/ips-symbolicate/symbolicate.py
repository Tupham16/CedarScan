import sys, json, re
from macho import MachO
from dwarfline import LineTable, SymTab

LOAD = 0x100000000

def demangle_hint(n):
    return n

def run(dsym, ips, offsets=None):
    m = MachO(dsym)
    print('dSYM UUID :', m.uuid)
    head = open(ips, 'r', encoding='utf-8').readline()
    meta = json.loads(head)
    print('IPS  uuid :', meta['slice_uuid'], '  app_version', meta['app_version'])
    print('UUID MATCH:', str(m.uuid) == meta['slice_uuid'])
    body = json.loads(open(ips, 'r', encoding='utf-8').read().split('\n', 1)[1])
    lt = LineTable(m)
    st = SymTab(m)
    print('line rows :', len(lt.rows), ' symbols:', len(st.addrs))
    print()
    th = [t for t in body['threads'] if t.get('triggered')][0]
    for i, f in enumerate(th['frames']):
        idx = f['imageIndex']
        img = body['usedImages'][idx]
        if img.get('name') != 'CedarScan':
            continue
        off = f['imageOffset']
        addr = LOAD + off
        name, delta = st.lookup(addr)
        row = lt.lookup(addr)
        row_prev = lt.lookup(addr - 1)
        print('frame %-3d imageOffset %d (0x%x) -> 0x%x' % (i, off, off, addr))
        print('   symbol : %s + %s' % (name, delta))
        if row:
            print('   line@pc: %s:%d:%d' % (row[1], row[2], row[3]))
        if row_prev and (not row or row_prev[:4] != row[:4]):
            print('   line@pc-1: %s:%d:%d' % (row_prev[1], row_prev[2], row_prev[3]))
        print()

if __name__ == '__main__':
    run(sys.argv[1], sys.argv[2])
