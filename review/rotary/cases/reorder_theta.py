#!/usr/bin/env python3
"""reorder_theta.py in.msh out.msh: renumber the volume elements of a gmsh 4.1 mesh by their angle
around the x axis, so that SFC partitioning cuts the sector in theta and the rotary periodic faces
(theta = 0 and theta = 120 deg) end up on different ranks (MPI rotary faces)."""
import math, sys

lines = open(sys.argv[1]).read().split('\n')
i = lines.index('$Nodes')
nblocks, nnodes, _, _ = map(int, lines[i + 1].split())
coords = {}
k = i + 2
for _ in range(nblocks):
    dim, tag, param, n = map(int, lines[k].split()); k += 1
    tags = [int(t) for t in lines[k:k + n]]; k += n
    for t, c in zip(tags, lines[k:k + n]):
        coords[t] = tuple(map(float, c.split()[:3]))
    k += n

j = lines.index('$Elements')
nblocks = int(lines[j + 1].split()[0])
k = j + 2
for _ in range(nblocks):
    dim, tag, etype, n = map(int, lines[k].split())
    body = lines[k + 1:k + 1 + n]
    if dim == 3:
        rows = [l.split() for l in body]
        old_tags = sorted(int(r[0]) for r in rows)
        def theta(r):
            nodes = [coords[int(t)] for t in r[1:9]]
            y = sum(p[1] for p in nodes) / 8; z = sum(p[2] for p in nodes) / 8
            x = sum(p[0] for p in nodes) / 8
            return (round(math.degrees(math.atan2(z, y)), 6), round(math.hypot(y, z), 6), round(x, 6))
        rows.sort(key=theta)
        lines[k + 1:k + 1 + n] = [' '.join([str(t)] + r[1:]) for t, r in zip(old_tags, rows)]
    k += n + 1

open(sys.argv[2], 'w').write('\n'.join(lines))
