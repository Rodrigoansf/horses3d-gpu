## Positivity limiter: measure pressure against the pressure of the average state

**Base:** `develop` · **Branch:** `change/limiter-pressure-reference` · 1 commit · same change as legacy

This is the GPU twin of the legacy PR of the same name. **It changes results, so it should be decided together with the legacy one.** The legacy PR explains the reasoning slowly. Here is the short version.

In pass 2 of `stage_limiter`, the pressure correction is

```
theta_p = (pavg - m) / (pavg - minp),     m = min(LIMITER_MIN, pavg)
```

Today `pavg` is the volume average of the nodal pressures. This PR uses the pressure of the cell-average state instead:

```fortran
! Pass 2. Reference is p(qavg), not the mean nodal pressure: p is concave in Q,
! so this theta keeps every node >= m = min(LIMITER_MIN, p(qavg)) (Zhang & Shu, 2010)
pavg = gm1 * (qavg(5) - 0.5_RP * sum(qavg(2:4)**2) / qavg(1))
```

Pressure is concave, so the mean nodal pressure is never larger than `p(qavg)`. **The current code is safe; it just limits more than it needs to.** With `p(qavg)` it applies the smallest correction that keeps every node at or above `m`. That is the Zhang–Shu limiter.

GPU-specific: the weighted pressure sum is removed from both vector loops, so the `reduction(+:pavg)` goes away. Each element does a little less work, and there are no new transfers.

### Results

This changes `LimiterTest`, the only GPU test where the pressure branch activates. Its references are updated:

| residual (it. 100) | old | new |
|---|---|---|
| continuity | 74.208378015 | 74.207930367 |
| x-momentum | 20.014725058 | 20.019174814 |
| y-momentum | 1.7529533585 | 1.7528722377 |
| z-momentum | 50.892385073 | 50.891671997 |
| energy | 51.458096712 | 51.457985082 |

The differences are 2e-6 to 2e-4 relative. Legacy horses3d reproduces both rows exactly on the CPU: the old one on master, and the new one with the legacy PR.

### How it was checked

- CPU (gfortran 13, serial): `LimiterTest` 8/8 with the new references.
- GPU: not yet run with this change. It's on the list for the next laptop run.
