## GMM_develop: what the direct push adds (no PR)

`GMM_develop` is Rodrigo's research branch, so these go in directly (fast-forward), after testing. This replaces the old fork PR #2 ("GMM_develop: minor fixes"), which can be closed.

On top of `GMM_develop` (`630879e6`), in this order:

| # | commit | kind | same as |
|---|---|---|---|
| 1 | Face_Assign: deep-copy geom and storage instead of aliasing (zalbanob) | fix | develop minor-fixes PR |
| 2 | Map every constructed NodalStorage order to the device (zalbanob) | fix | develop minor-fixes PR |
| 3 | Local gradients: keep the state path for physics without gradient variables | fix: `make mu` builds again | GMM only |
| 4 | TE sensor: build the coarse mesh with pAdapt_MPI in MPI runs (zalbanob) | fix | develop minor-fixes PR, legacy |
| 5 | OpenMP: share sensor and module data in default(private) sensor loops (zalbanob) | fix | develop minor-fixes PR, legacy |
| 6 | SVV (energy gradient variables): fix the velocity divergence (zalbanob) | changes results | develop SVV PR, legacy |
| 7 | TaylorGreenSVVLES: update the residual references for the SVV divV fix | test references | develop SVV PR, legacy |
| 8 | TE sensor: evaluate the user source term at each node, starting from zero (zalbanob) | changes results | develop TE PR, legacy |
| 9 | **SVV shock capturing: compute the filtered flux on the device** | GPU fix | GMM only |
| 10 | Merge develop into GMM_develop | merge | — |
| 11 | Strong-form split volume term: compute the sharp fluxes again (zalbanob) | changes results | develop split-form PR |
| 12 | Aliasing sensor: compute the sharp fluxes again | changes results | develop split-form PR |
| 13 | Aliasing sensor: keep the scratch arrays when the order does not change | crash fix | develop aliasing PR, legacy |
| 14 | ParamfileRegions: don't allocate a value only to deallocate it | nvfortran crash fix | develop ParamfileRegions PR |

The commits that also go to `develop` are identical there, so merging `develop` into `GMM_develop` again later is clean.

### 9. SVV on the GPU

The SVV method was the one shock-capturing method left on the host path of `TimeDerivative_ComputeArtificialViscosity`. That path read `Q` and the gradients from the host, which on the GPU are only refreshed once per time step, and it never pushed the element `AviscContravariantFlux` back to the device. So on the GPU every RK stage after the first used stale data and the volume term never saw the SVV flux: `TaylorGreenSVVLES` passed 3 of 8 asserts on the GPU and 8 of 8 on the CPU.

It is now ported like the other methods (the `SCDEV_DISPATCH` convention in `ShockCapturing.f90`):
- `SC_FlattenMethod` also flattens `SC_SVV_t`: the square roots of the viscosities, the update method and the Smagorinsky constants. `SCdev_onDevice` stays true.
- `InitializeSVV` / `SVV_UpdateFilters` copy the filter matrices into `SVVdev_filter(i,l,N)`, and replace the `Compute_Hflux` / `Compute_SVV` procedure pointers with an integer (`SVVdev_kind`) read by `SVV_Hflux_0D` / `SVV_Flux_0D`. The six pointwise flux routines become `!$acc routine seq`; their array constructors are written out element by element, in the same order, so the CPU arithmetic is unchanged.
- `SC_ComputeElementSVVFlux` does, element by element on the device, what `SVV_viscosity` + `SVV_ComputeInnerFluxes` did: `H = sqrt(J) Hflux`, the three 1-D filter passes through a per-element scratch (`SVVdev_W`, the size of `AviscContravariantFlux`, allocated only for SVV runs), then the SVV flux in contravariant form. sqrt(mu) and sqrt(alpha) are computed once per node and kept in `SVVdev_mu`.
- `SC_UpdateHostArtificialDiss` brings the per-element dissipation back in one contiguous transfer, for the SVV volume monitor.

No `Q` or gradient transfers are added. The face prolongation is unchanged: like the other methods, SVV now goes through `SC_ProlongAviscFluxToFaces` (still a host round trip, as before; porting it is the remaining step for a fully device-resident artificial viscosity).

Two things found while porting, not changed beyond what the port needs:
- With the Smagorinsky update and no `alpha/mu` ratio, `SVV_viscosity` would leave `alpha` undefined, but that combination never runs: `AV_initialize` stops with "Alpha must be proportional to mu when using shock-capturing with LES". The device path's zero is only a default (the commit message and code comment overstate this).
- `SC_viscosity` (host) never applies the first method where `sensor >= 1`, but the device `SC_ComputeElementAviscFlux` does when there is no second method. SVV keeps the host behaviour; the non-SVV device path is unchanged.

Results, before the develop merge (`gmm/next`):
- GPU, `TaylorGreenSVVLES`: 3/8 → **8/8**. Residuals match the CPU references to 5e-9 (momentum), 1.3e-8 (energy), 2e-7 (continuity); SVV dissipation monitor to 5e-13. The result is bit-identical to the host-sync experiment of the Oct 7 GPU run, which copied Q and the gradients back at every stage.
- CPU (gfortran), `TaylorGreenSVVLES`: **bitwise identical** before and after the port, all four monitor files, and the same speed (1.64 s vs 1.62 s in the artificial-viscosity routine over 30 calls).

### Merge with develop (10)

One conflict, in `TimeDerivative_VolumetricContribution_Split`: develop (c99e3095) folds the viscous contribution into `ScalarWeakIntegrals_SplitVolumeDivergence` and drops the separate `ScalarWeakIntegrals_StdVolumeGreen` call; `GMM_develop` subtracts the artificial-viscosity flux from `contravariantFlux` right before that call. Kept the subtraction and develop's single call, which now consumes `contravariantFlux` with the artificial viscosity included.

### How it was checked

GPU (RTX 3060 laptop, nvfortran 26.3, one GPU):
- Before the merge (`gmm/next`, commits 1–9) against `GMM_develop`: 18 of the 19 cases (the CI list plus `CylinderGMM`, `ForwardFacingStepSVV`, `TaylorGreenSVVLES`) bitwise identical; `TaylorGreenSVVLES` 3/8 → 8/8; `ForwardFacingStepSVV` crashes on both (illegal address in `HexMesh_ComputeLocalGradientNS`, known). `make mu` builds; `Multiphase/EntropyConservingTest` 5/5.
- Final branch (all 14 commits, develop merged in):
  - The 16 NS cases of the GPU CI and `Multiphase/EntropyConservingTest` pass all their asserts and are **bitwise identical to `develop`**. So, outside shock capturing, `GMM_develop` now computes exactly what `develop` does. `Cylinder` runs with its unmodified control file (commit 14).
  - Against the branch before the merge they move only by round-off, from develop's unified split volume integral: residuals ~5e-13 relative, drag ~4e-16, lift ~1e-10; the `wake_u` probe sits at ±1e-16 (numerically zero).
  - `TaylorGreenSVVLES` 8/8, `CylinderGMM` 5/5 (1e-10 from the merge). `ForwardFacingStepSVV` still crashes, as on `GMM_develop` today (illegal address in `HexMesh_ComputeLocalGradientNS`, separate issue).
  - TE scratch cases (`te`, `te-std`, `te-alias`): all run to the end; sensor 0.0 in every element; sensor and SVV monitors agree with the CPU build to 1e-14.

CPU (gfortran), final branch:
- `TaylorGreenSVVLES` 8/8. Against the branch before the merge it moves only by round-off, from develop's unified split volume integral: kinetic energy 2e-16, SVV dissipation 2e-14, residuals 1e-6 relative on values of about 4e-10.
- The three TE scratch cases run to the end, `te-alias.control` included (it segfaulted before commit 13). The sensor is 0.0 in every element at steps 1–3, as in legacy.

Not checked: multi-GPU and MPI (cluster).
