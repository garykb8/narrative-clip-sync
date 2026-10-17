import re, struct, subprocess, sys
binp, disasm, out = sys.argv[1:4]
data = open(binp, 'rb').read()
# parse Mach-O 64 segments/sections
ncmds = struct.unpack_from('<I', data, 16)[0]; off = 32; secs = []
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', data, off)
    if cmd == 0x19:
        nsects = struct.unpack_from('<I', data, off+64)[0]
        for i in range(nsects):
            s = off + 72 + i*80
            sect = data[s:s+16].rstrip(b'\0').decode(); seg = data[s+16:s+32].rstrip(b'\0').decode()
            addr, sz, foff = struct.unpack_from('<QQI', data, s+32)
            secs.append((seg, sect, addr, sz, foff))
    off += size
def a2o(a):
    for seg, sect, addr, sz, foff in secs:
        if addr <= a < addr+sz and foff: return foff + a - addr
def cfstr(a):
    o = a2o(a)
    if o is None: return None
    isa, flags, ptr, ln = struct.unpack_from('<QQQQ', data, o)
    p = a2o(ptr)
    if p is None or ln > 4096: return None
    raw = data[p:p+(ln*2 if flags & 0x4 == 0 and flags not in (0x7c8, 0x7d0) and False else ln)]
    if flags == 0x7d0: raw = data[p:p+ln*2]; return raw.decode('utf-16le', 'replace')
    return raw.decode('utf-8', 'replace')
lines = open(disasm).read().split('\n'); res = []
for i, l in enumerate(lines):
    m = re.search(r'(-?0x[0-9a-f]+)\(%rip\)', l)
    if m and 'bad cfstring' in l:
        nxt = next((x for x in lines[i+1:i+4] if re.match(r'^[0-9a-f]{16}\t', x)), None)
        if nxt:
            tgt = int(nxt.split('\t')[0], 16) + int(m.group(1), 16)
            s = cfstr(tgt)
            if s is not None: l = l.replace('@"bad cfstring ref"', '@' + repr(s))
    res.append(l)
open(out, 'w').write('\n'.join(res))
