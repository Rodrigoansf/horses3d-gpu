## Positivity limiter: measure pressure against the pressure of the average state

This PR changes one line in the positivity limiter. It changes results, so it's here to be discussed rather than merged as a plain bug fix. It's one of five small, independent PRs that came out of reviewing the GPU version of HORSES3D.

### How the limiter works today

After every Runge–Kutta stage, `stage_limiter` (in `ExplicitMethods.f90`) visits each element. If density or pressure has dropped too low, it pulls the solution back toward the element average. It does this in two steps.

1. **Density.** It computes the element average `Qavg` and finds the smallest nodal density. If that minimum is below `LIMITER_MIN`, it moves every nodal density part of the way toward `Qavg(1)`.
2. **Pressure.** It does the same thing for pressure, except that it moves the whole state, not just one variable:

   ```
   theta = (pavg - m) / (pavg - minp)
   Q     = Qavg + theta * (Q - Qavg)
   ```

   Here `minp` is the smallest nodal pressure and `m = min(LIMITER_MIN, pavg)`.

The question is what `pavg` should be. Today it is **the average of the nodal pressures**: each node's pressure, weighted by its quadrature weight and Jacobian, divided by the element volume.

### What this PR changes

`pavg` becomes **the pressure of the average state**:

```fortran
pavg = gm1 * (Qavg(5) - 0.5_RP * (Qavg(2)**2 + Qavg(3)**2 + Qavg(4)**2) / Qavg(1))
```

The weighted sum of nodal pressures is no longer needed, so those two lines go away. Nothing else changes.

### Why

The limiter moves each node along the straight line from `Qavg` to the node's own state. So what matters is the pressure along that line.

Pressure is a concave function of the conserved variables. For any `theta` between 0 and 1, that means:

```
p(Qavg + theta (Q - Qavg))  >=  p(Qavg) + theta (p(Q) - p(Qavg))
```

If `theta` is computed with `p(Qavg)` as the reference, the right-hand side is at least `m` at every node. So after limiting, every node has a pressure of at least `m = min(LIMITER_MIN, p(Qavg))`. This is the simplified positivity limiter of Zhang and Shu.

With today's reference, the average of the nodal pressures, Jensen's inequality says that average can only be smaller than `p(Qavg)`. A smaller reference gives a smaller `theta`. So the current code pulls the solution further toward the average than it needs to. **It is still safe. It just adds more dissipation than necessary.**

There is one case where the current code does nothing when it should act. If every nodal pressure in an element is the same, and below `LIMITER_MIN`, then the average equals the minimum, and the `if (pavg /= minp)` test skips the element. With `p(Qavg)` as the reference that case is handled.

### About the old comment

The line being replaced says:

```fortran
! Pressure now (Jensen's inequality is NOT conservative for the pressure)
```

We read this as: the average of the pressures is not the pressure of the average, and the average of the pressures was chosen on purpose as the more cautious option. If there was another reason (a case that misbehaved, or a reference we don't know about), we'd really like to hear it. That is the main thing to decide here.

### What changes in the results

- **Existing tests: nothing.** The only legacy test that turns the limiter on is `ForwardFacingStep_SSPRK33`. It passes 5/5, and its final solution file is bit-identical with and without this change. The pressure branch never activates there in 10 steps.
- **When the pressure branch does activate.** We ran a Mach 3 cylinder (`CylinderNSpol3.mesh`, P=3, SSPRK33, `Limiter minimum = 1e-5`, 100 steps). Residuals at step 100:

  | | continuity | x-momentum | y-momentum | z-momentum | energy |
  |---|---|---|---|---|---|
  | master | 74.208378015 | 20.014725058 | 1.7529533585 | 50.892385073 | 51.458096712 |
  | this PR | 74.207930367 | 20.019174814 | 1.7528722377 | 50.891671997 | 51.457985082 |

  The differences are between 2e-6 and 2e-4 relative.

  This case is the GPU version's `LimiterTest`, and legacy reproduces its numbers exactly, before and after the change. If we keep this PR, it would be worth adding that case to legacy as a test, because today nothing in the legacy test suite exercises the pressure step of the limiter. That could be a separate PR.

### How it was checked

- Built with gfortran 13 (`make ns`, serial).
- `ForwardFacingStep_SSPRK33`: 5/5, bit-identical final solution.
- The Mach 3 cylinder above, run on master and on this branch.

### Reference

X. Zhang and C.-W. Shu, *On positivity-preserving high order discontinuous Galerkin schemes for compressible Euler equations on rectangular meshes*, J. Comput. Phys. 229 (2010) 8918–8934.
