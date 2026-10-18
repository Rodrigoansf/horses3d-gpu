## GMM_develop to develop: shock capturing and gradient variables on the GPU

On `develop`, shock capturing is accepted from the control file and then contributes exactly nothing: the artificial viscosity is computed nowhere in the time step, on the CPU or the GPU. This PR brings Rodrigo's `GMM_develop` work to `develop`. Shock capturing is wired back into the time derivative and runs on the device, the gradient variables (state, energy, entropy) are dispatched on the device, the GMM shock sensor runs on the GPU, and SVV, the one method that was still on the host, now runs on the device too.

It is the `GMM_develop` branch rebuilt on today's `develop` as one feature: its own 11 commits, the `make mu` fix and the SVV port. The review fixes that `GMM_develop` also carries come to `develop` through their own PRs. All the feature PRs, this one included, merge cleanly in any order.

### What it contains

**Shock capturing on the device** (`SCDEV_DISPATCH` in `ShockCapturing.f90`)
- *Rewire artificial viscosity and dispatch gradient variables on device.* The polymorphic shock-capturing methods and their procedure pointer can't be called from OpenACC, so the configuration is flattened into module scalars on the device and the pointer becomes a `select case` in an `!$acc routine seq`. The artificial-viscosity flux is computed per element on the device and enters the volume, interior-face and boundary-face terms.
- *Push the received MPI artificial-viscosity flux to the device*, so partition faces don't use the previous stage's value.
- *Mark GuermondPopovFlux_ENTROPY as an OpenACC device routine*: without it `make ns COMPILER=nvfortran` fails.
- **SVV on the device.** SVV was left on the host path, which read stale `Q` and gradients and never sent the flux back: `TaylorGreenSVVLES` passed 3/8 on the GPU. The SVV settings and filter matrices now go to the device and one kernel per element computes the filtered flux. No `Q` or gradient transfers are added, and the CPU result is bitwise unchanged at the same speed.

**Gradient variables** (`GRADVARS_DISPATCH`)
- *Gradient Variables initial commit* and the dispatch above: the BR1 gradients are taken of W(Q) for the selected variables, on the device.
- *Fix velocity gradients from entropy-variable gradients*: the chain rule was wrong (`grad u = (p/rho)(grad W(2:4) + u grad W(5))`); it only agreed where p/rho = 1.
- *LES models* and *horses2plt* read the stored gradients in the selected gradient variables; *horses2plt* also takes gamma and R from the solution file, so entropy-variable gradients are no longer NaN.
- *Local gradients: keep the state path for physics without gradient variables*: `make mu` (and NSSA) build again.

**GMM shock sensor**
- *Avoid nvfortran maxloc(dim=2) heap corruption*: every GPU run with `Shock sensor = GMM` aborted at the first sensor evaluation.
- *Deterministic, compiler-independent initial centroids*: the sensor was not reproducible from run to run, nor between CPU and GPU.

**Compiler**: *work around an nvfortran 26.3 ICE in MPI builds of HexMesh*.

### What changes in results

Nothing changes for a case that doesn't enable shock capturing: on the GPU and on the CPU, every such CI case gives bitwise the same residuals and monitors as `develop` (details below). The shock-capturing cases now get their artificial viscosity:

| case (GPU) | `develop` | this PR |
|---|---|---|
| `TaylorGreenSVVLES` (SVV, sensor `ones`) | 3/8: the SVV term is never applied (its SVV-dissipation monitor reads 0) | 8/8 |
| `CylinderGMM` (GMM sensor, non-filtered + Guermond-Popov) | not run by the GPU CI | 5/5 |
| `ForwardFacingStepSVV` (SVV + Guermond-Popov on a 2D mesh) | not run by the GPU CI | crashes in the first step; 6/6 together with the GPU device-data PR |

`ForwardFacingStepSVV` crashing is not a shock-capturing bug: its 2D mesh has polynomial order 0 in the offset direction, and on `develop` the GPU can only index one polynomial order. The GPU device-data PR fixes that for every multi-order case; with both PRs merged (branch `goal/end-goal`), `ForwardFacingStepSVV` passes 6/6 on the GPU.

`TaylorGreenSVVLES` passes with `develop`'s reference values. The SVV `divV` PR changes those references, because it fixes the SVV dissipation itself; with both PRs merged it passes 8/8 against the new references.

### How it was checked

GPU (RTX 3060 laptop, nvfortran 26.3, one GPU), this branch alone against `develop`:
- The 16 non-shock-capturing cases of `CI_serial_GPU.yml` (`Cylinder` with one local, uncommitted control-file line, see the ParamfileRegions PR), `IBM_Cylinder`, `LimiterTest`, the multiphase `EntropyConservingTest`, `ActuatorLineInterpolation` and the three truncation-error scratch cases: bitwise identical, with the same assertion results.
- The shock-capturing cases: see the table above.
- Against `GMM_develop` as pushed (`gmm/final`, which also carries the review fixes): bitwise identical on every case except `TaylorGreenSVVLES`, whose difference is the SVV `divV` fix that `gmm/final` has and this PR leaves to its own PR.

CPU (gfortran, serial), this branch against `develop`, the cases of `CI_serial_NS`, `CI_parallel_NS`, `CI_serial_MU` and `CI_parallel_MU` run serially (29 control files): 26 bitwise identical, with the same assertion results; the three `UniformFlow` HDF5 variants need HDF5, which this laptop's build doesn't have. `Channel` (3/5) and `DualTimeStepping` (stops with exit code 2) fail identically on `develop`. The `CI_horses2plt` steps pass 12/12 and the `CI_mergeStatistics` steps 7/7 (both run locally with `gpu-wt/tools/ci_local.py`).

**Not checked:** multi-GPU and MPI (cluster). The GMM sensor's MPI path and the MPI artificial-viscosity exchange need a cluster run.
