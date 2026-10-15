## SVV with energy gradient variables: fix the velocity divergence

This is the GPU twin of the legacy PR of the same name, which has the full explanation. In short:

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

### How it was checked (CPU, gfortran 13, serial)

| | old references | new references |
|---|---|---|
| `GMM_develop` | 8/8 | – |
| this branch | 5/8 (only the five residuals move) | 8/8 |

This branch matches the legacy fixed values to about 1e-11. The test tolerance is 1e-7.

### Notes

- Merge together with the legacy PR, or after it, so the references stay in sync.
- On the GPU itself, `TaylorGreenSVVLES` doesn't yet reproduce the CPU, with or without this fix. The SVV branch of `TimeDerivative_ComputeArtificialViscosity` runs on the host without refreshing `Q`/gradients and doesn't push the flux back. That was found in the laptop GPU run and is a separate issue.
