## SVV with energy gradient variables: fix the velocity divergence

This is the GPU twin of the legacy PR of the same name, which has the full explanation. It targets `develop`; `GMM_develop` already has the same commits. In short:

`SVV_physical_dissipation_ENERGY` (`SVV.f90`) computes

```fortran
divV = Hx(IX) + Hy(IY) + Hz(IZ)          ! = d(rho)/dx + du/dy + dv/dz
```

With energy gradient variables the gradients are ordered (rho, u, v, w, T), so the right line is

```fortran
divV = Hx(IRHOU) + Hy(IRHOV) + Hz(IRHOW) ! = du/dx + dv/dy + dw/dz
```

The rest of the routine already uses those indices. The line was copied from `ViscousFlux_ENERGY`, where `U_x` is a 3-component velocity slice, and the slice was lost in the copy.

### Commits

1. The one-line fix (zalbanob, from horses-framework/horses3d-gpu#116).
2. The new residual references for `TaylorGreenSVVLES`, the only test that uses SVV with energy gradient variables. They are **the same values as in the legacy PR**, so the two codes keep sharing one reference.

### How it was checked

**CPU (gfortran), on `GMM_develop`**, where the shock capturing is wired into the time derivative:

| | old references | new references |
|---|---|---|
| `GMM_develop` | 8/8 | – |
| `GMM_develop` + this fix | 5/8 (only the five residuals move) | 8/8 |

These match the legacy fixed values to about 1e-11. The test tolerance is 1e-7.

**On `develop` this change has no effect yet.** In `develop`, `TimeDerivative_ComputeQDot` never adds the artificial viscosity: the shock-capturing flux is only computed in the host routine `TimeDerivative_StrongVolumetricContribution`, which the time step doesn't use. So on `develop`, CPU and GPU, `TaylorGreenSVVLES` runs without any SVV (its SVV dissipation monitor is exactly 0) and fails 5 of 8 asserts, before and after this PR, with bitwise identical output. The fix and the references start to matter when the artificial-viscosity work of `GMM_develop` reaches `develop`.

GPU (RTX 3060 laptop), this branch against `develop`: all 18 cases (the GPU CI list plus `TaylorGreenSVVLES`) bitwise identical.

It is still worth merging now: the code is then the same as legacy and as `GMM_develop`, and `TaylorGreenSVVLES` keeps one reference for all three.

### Notes

- Merge together with the legacy PR, or after it, so the references stay in sync.
- On the GPU, SVV works on `GMM_develop` only. There the SVV branch of `TimeDerivative_ComputeArtificialViscosity` used to run on the host without refreshing `Q`/gradients and without pushing the flux back (3/8 on the GPU). That is now fixed on `GMM_develop` by porting the SVV filter to the device; `TaylorGreenSVVLES` passes 8/8 on the GPU there and matches the CPU to about 1e-8.
