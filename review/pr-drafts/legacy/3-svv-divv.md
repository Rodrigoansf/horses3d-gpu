## SVV with energy gradient variables: fix the velocity divergence

This PR fixes one index in the SVV dissipation flux. The fix itself is clear. But it changes the results of `TaylorGreenSVVLES`, so that test's reference values have to be updated too, and that part deserves a second pair of eyes. It's one of five small, independent PRs that came out of reviewing the GPU version of HORSES3D.

### Where this code is

When shock capturing uses SVV with the physical dissipation flux and **energy** gradient variables, the SVV flux is built in `SVV_physical_dissipation_ENERGY` (in `SVV.f90`). The routine receives the filtered gradients `Hx`, `Hy`, `Hz`. With energy gradient variables these are gradients of

```
(rho, u, v, w, T)        at positions  IRHO, IRHOU, IRHOV, IRHOW, IRHOE  (1..5)
```

So `Hx(IRHOU)` is du/dx, `Hy(IRHOV)` is dv/dy, `Hz(IRHOW)` is dw/dz, and `Hx(IRHO)` is d(rho)/dx.

### The bug

The routine computes the velocity divergence as:

```fortran
divV = Hx(IX) + Hy(IY) + Hz(IZ)
```

`IX`, `IY`, `IZ` are 1, 2, 3. So this adds up **d(rho)/dx + du/dy + dv/dz**, which is not a divergence. The very next lines use the right components, for example:

```fortran
F(IRHOU,IX) = sqrt_mu * (2.0_RP * Hx(IRHOU) - 2.0_RP/3.0_RP * divV )
```

### How it probably happened

This routine is a copy of the physical viscous flux `ViscousFlux_ENERGY` in `Physics_NS.f90`. There, the code first takes the velocity part of the gradient:

```fortran
u_x = Q_x(IRHOU:IRHOW)
...
divV = U_x(IX) + U_y(IY) + U_z(IZ)
```

and there `U_x(IX)` really is du/dx, because `u_x` is the 3-component velocity slice. When the code was copied into SVV, the slice step was dropped. `U_x(IX)` became `Hx(IX)`, which now points at the density gradient. All the other terms were translated correctly; only this line was missed.

### The fix

```fortran
divV = Hx(IRHOU) + Hy(IRHOV) + Hz(IRHOW)
```

After this change, `SVV_physical_dissipation_ENERGY` computes exactly what `ViscousFlux_ENERGY` computes. The filtered gradients `Hx/Hy/Hz` play the role of the gradients, `sqrt_mu` plays the role of the viscosity, `kappa = sqrt_mu * mu_to_kappa` plays the role of the conductivity, and the bulk viscosity is zero. A possible follow-up would be to replace the copy with a call to `ViscousFlux_ENERGY`, so the two can't drift apart again. We kept this PR to the one-line fix so it's easy to review.

### Which tests are affected

Only one legacy test uses SVV together with energy gradient variables: `NavierStokes/TaylorGreenSVVLES`. It runs in the parallel CI. (`ForwardFacingStepSVV` uses entropy variables, which go through a different routine.)

With the fix, its five residual asserts change. The new values in this PR come from running the test with the fix (gfortran 13, serial):

| residual (iteration 10) | old reference | new reference | change |
|---|---|---|---|
| continuity | 9.768839029729e-5 | 9.6089299201416065e-5 | −1.6 % |
| x-momentum | 0.127069145556453 | 0.12704234777396151 | −0.021 % |
| y-momentum | 0.127055963394165 | 0.12704234731965755 | −0.011 % |
| z-momentum | 0.250048505485785 | 0.25000646761649736 | −0.017 % |
| energy | 0.628947793858187 | 0.62824891369699054 | −0.11 % |

Before updating them, we checked that master reproduces the old values on our machine (8/8 pass), and that the branch with the fix and the new values also passes 8/8.

### Something we noticed but didn't change

The other three asserts in this test (kinetic energy, kinetic-energy rate, SVV dissipation) still pass with the fix. They would pass with almost anything, though. Their tolerance is 1e-7, larger than the quantities themselves, and their stored values already don't match current master. For example, the kinetic-energy rate is stored as −7.6e-8, while master gives −2.4e-8. That is unrelated to this PR, so we left it alone, but it may be worth a separate look.

### How it was checked

- Built with gfortran 13 (`make ns`, serial).
- `TaylorGreenSVVLES`: master 8/8 with the old values; this branch 5/8 with the old values (only the five residuals move) and 8/8 with the new ones.
- The GPU version of HORSES3D, built for the CPU with gfortran, gives the same five numbers with the same fix (and the old ones without it).
- Rebased on master `a01ca08b4`. All 59 Navier–Stokes and multiphase cases of the serial CI workflows were run with gfortran (serial) on master and with all five legacy PRs of this review stacked. 56 give bitwise-identical output; two of those stop on both builds because the test machine has no MKL (`RisingBubble`, multiphase `Convergence`). `TaylorGreenSVVLES` changes, as described in the SVV PR, and passes 8/8 on both sides (old references on master, new ones with the PRs). `CylinderGMM` is not reproducible run to run: one of three runs of the PR build differed, the other two matched master, which gave three identical runs (its asserts pass every time). `VirtualSurfaces_acoustics_pAdaptationRL` needs HDF5, which the test machine doesn't have.
