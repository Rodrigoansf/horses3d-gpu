#!/usr/bin/env python3
"""split_pairs.py sector.msh out.msh: split the two periodic surfaces of the PR's sector mesh at r = 6
into two physical groups each (sidea_in/sidea_out, sideb_in/sideb_out), keeping the single volume
entity. Gives a case with two rotary periodic pairs on exactly the same nodes as the sector."""
import math, sys

L = open(sys.argv[1]).read().split('\n')
SPLIT = {5: 105, 27: 127}            # surface entity -> new entity for r > 6
NEWPHYS = {105: 8, 127: 9}

# physical names
i = L.index('$PhysicalNames')
n = int(L[i + 1])
names = L[i + 2:i + 2 + n]
names = [s.replace('"sidea"', '"sidea_in"').replace('"sideb"', '"sideb_in"') for s in names]
names += ['2 8 "sidea_out"', '2 9 "sideb_out"']
L[i + 1:i + 2 + n] = [str(len(names))] + names

# entities: duplicate surface 5 and 27 lines with new tags/physical tags; add them to the volume
i = L.index('$Entities')
np_, nc, ns, nv = map(int, L[i + 1].split())
k = i + 2 + np_ + nc
surf = L[k:k + ns]
new = []
for s in surf:
    p = s.split()
    if int(p[0]) in SPLIT:
        t = SPLIT[int(p[0])]
        q = [str(t)] + p[1:7] + ['1', str(NEWPHYS[t]), '0']
        new.append(' '.join(q) + ' ')
L[k:k + ns] = surf + new
L[i + 1] = f'{np_} {nc} {ns + len(new)} {nv}'
k += ns + len(new)
v = L[k].split()                      # tag bbox(6) nphys phys nbs surfaces...
nphys = int(v[7]); pos = 8 + nphys
nbs = int(v[pos]); bs = v[pos + 1:pos + 1 + nbs] + ['105', '-127']
L[k] = ' '.join(v[:pos] + [str(len(bs))] + bs) + ' '

# node coordinates
i = L.index('$Nodes')
nb = int(L[i + 1].split()[0]); k = i + 2; xyz = {}
for _ in range(nb):
    d, t, prm, n = map(int, L[k].split()); k += 1
    tags = [int(x) for x in L[k:k + n]]; k += n
    for tg, c in zip(tags, L[k:k + n]):
        xyz[tg] = tuple(map(float, c.split()[:3]))
    k += n

# elements: split the blocks of entities 5 and 27 by the radius of the first 4 nodes
i = L.index('$Elements')
h = L[i + 1].split(); nbl = int(h[0]); k = i + 2; out = []
for _ in range(nbl):
    d, t, et, n = map(int, L[k].split())
    body = L[k + 1:k + 1 + n]
    if d == 2 and t in SPLIT:
        inn, outr = [], []
        for e in body:
            p = e.split()
            r = sum(math.hypot(xyz[int(x)][1], xyz[int(x)][2]) for x in p[1:5]) / 4
            (outr if r > 6.0 else inn).append(e)
        out += [f'{d} {t} {et} {len(inn)}'] + inn + [f'{d} {SPLIT[t]} {et} {len(outr)}'] + outr
        nbl_add = 1
    else:
        out += [L[k]] + body
    k += n + 1
L[i + 2:k] = out
L[i + 1] = ' '.join([str(nbl + 2)] + h[1:])
open(sys.argv[2], 'w').write('\n'.join(L))
