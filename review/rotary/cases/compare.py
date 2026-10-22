#!/usr/bin/env python3
"""compare.py <run tag A> <run tag B> [...]: max difference of every probe between two runs (all
iterations), relative to the probe's range in run A. Runs are in design/review-rotary/runs/<tag>/."""
import glob, os, sys
import numpy as np

RUNS = '/home/rodrigo/Desktop/Horses3d-Epicure/gpu-wt/design/review-rotary/runs'

def probes(tag):
    out = {}
    for f in sorted(glob.glob(os.path.join(RUNS, tag, '*.probe'))):
        name = f.split('.')[-2]
        rows = []
        for line in open(f):
            parts = line.split()
            if parts and parts[0].isdigit():
                rows.append([float(p) for p in parts])
        out[name] = np.array(rows)
    return out

def residuals(tag):
    f = glob.glob(os.path.join(RUNS, tag, '*.residuals'))[0]
    return np.loadtxt(f, skiprows=1)

def main(a, b):
    pa, pb = probes(a), probes(b)
    worst = 0.0
    lines = []
    for k in sorted(pa):
        if k not in pb:
            lines.append(f'{k}: missing in {b}'); continue
        n = min(len(pa[k]), len(pb[k]))
        va, vb = pa[k][:n, -1], pb[k][:n, -1]
        scale = max(np.ptp(va), 1e-300)
        d = np.nanmax(np.abs(va - vb)) if np.all(np.isfinite(vb)) else np.inf
        worst = max(worst, d / scale)
        lines.append(f'{k:14s} final A={va[-1]: .10e} B={vb[-1]: .10e}  max|A-B|={d:.3e}  rel-to-range={d/scale:.3e}')
    ra, rb = residuals(a), residuals(b)
    n = min(len(ra), len(rb))
    # continuity, x-momentum (axial) and energy residuals are invariant under the rotation
    for c, nm in [(4, 'continuity'), (5, 'x-momentum'), (8, 'energy')]:
        d = np.nanmax(np.abs(ra[:n, c] - rb[:n, c]) / np.abs(ra[:n, c]))
        lines.append(f'residual {nm:10s}: max rel diff {d:.3e}  (final {ra[n-1,c]:.6e} vs {rb[n-1,c]:.6e})')
    print(f'### {a} vs {b}: worst probe diff relative to range = {worst:.3e}')
    print('\n'.join(lines))

if __name__ == '__main__':
    for b in sys.argv[2:]:
        main(sys.argv[1], b)
