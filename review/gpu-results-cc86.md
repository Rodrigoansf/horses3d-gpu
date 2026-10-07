# HORSES3D-GPU: single-GPU results on cc86

Tests a cloud session without a GPU could not run: sections A–F of the review plan, run on one
laptop GPU on 2026-10-07. Every run is a single process on a single GPU (`COMM=SERIAL`).

## Hardware and compilers

| Item | Value |
|---|---|
| GPU | NVIDIA GeForce RTX 3060 Laptop GPU, compute capability 8.6, 6144 MiB |
| Driver | 580.178.04 (`nvidia-smi` reports CUDA 13.0) |
| CPU / OS | Intel Core i7-12700H, 15 GiB RAM, Ubuntu 24.04.5, Linux 6.8.0-142 |
| GPU compiler | nvfortran 26.3-0 (NVIDIA HPC SDK 26.3, bundled CUDA 13.1) |
| GPU flags | `NVFORTRAN_RELEASE_FLAGS` with `-gpu=cc86,gvmode,ptxinfo,maxregcount:128` (local edit, not committed) |
| CPU reference compiler | GNU Fortran 12.4.0, `make ns mu COMPILER=gfortran COMM=SEQUENTIAL ENABLE_THREADS=NO` |
| Sanitizer | compute-sanitizer 2025.4.1 |

| Branch | Commit |
|---|---|
| `develop` | `ca6f0bd2` |
| `fix/gpu-port-develop` | `4f97e02a` |
| `GMM_develop` | `630879e6` |
| `fix/gpu-port-GMM` | `5fd506e4` |
| `discuss/legacy-shared-bugs` | `a1ed9df1` |
| legacy horses3d (CPU cross-check only) | `0d444d212` (Rodrigoansf/horses3d `master`) |

## Unexpected results

Most important first. Sections below have the evidence.

1. **E: the GPU does not reproduce the CPU for `TaylorGreenSVVLES` on `GMM_develop`.** The CPU
   passes 8/8 (reproduced locally with gfortran). The GPU passes 3/8 on `GMM_develop`,
   `fix/gpu-port-GMM` and `discuss/legacy-shared-bugs`, and its residuals leave the CPU's after
   the first time step. The cause is the SVV branch of `TimeDerivative_ComputeArtificialViscosity`
   (`Solver/src/NavierStokesSolver/SpatialDiscretization.f90`). It runs on the host, reads `Q`
   and the gradients without refreshing them from the device, and never pushes the element
   `AviscContravariantFlux` back to the device. Adding those two transfers (7 lines, shown in E)
   makes the GPU match the CPU within 1.3e-8 in the momentum and energy residuals, on both
   `GMM_develop` (8/8) and `discuss` (x-momentum 0.1270423471 vs CPU 0.1270423478).
2. **B: anisotropic polynomial orders crash on the GPU on both `develop` and
   `fix/gpu-port-develop`.** The first kernel, `HexMesh_ProlongSolToFaces`, hits an illegal
   address. This happens even on a structured periodic mesh where the CPU build runs and agrees
   with legacy horses3d to 3e-10. So commit 30d3f071 ("Map every constructed NodalStorage order")
   cannot be checked this way, and on its own it does not make anisotropic orders work on the
   GPU.
3. **B: on the Cylinder mesh, anisotropic orders give NaN on the CPU build of horses3d-gpu too.**
   Legacy horses3d runs the same case without problems. The port's `Face_AdaptSolToFace` only
   copies; it lost the `projectionType`/`Tset` interpolation that legacy uses on p-nonconforming
   faces. Rotated neighbours make faces p-nonconforming as soon as Nx≠Ny≠Nz. p-adapted meshes go
   through the same routine, so they are probably affected too (not tested).
4. **E: `ForwardFacingStepSVV` crashes on the GPU on both GMM branches.** It hits an illegal
   address; with `CUDA_LAUNCH_BLOCKING=1` the first faulting kernel is
   `HexMesh_ComputeLocalGradientNS` (`HexMesh.f90:5716`).
5. **D: the GPU volume monitors are stale, as suspected, and worse than "stale between saves".**
   On the GPU, kinetic energy stays at its initial-condition value and kinetic-energy rate and
   enstrophy are exactly 0 at every iteration. Host `Q` is refreshed only when a solution file is
   written, host `QDot` never, and host gradients only once, before any had been computed. The
   TaylorGreen asserts (tolerance 1e-11) would catch this. However, the test is commented out of
   the GPU CI, and the TaylorGreen32 mesh does not fit in 6 GB. The volume-monitor asserts of
   `TaylorGreenSVVLES` use tolerance 1e-7, which is larger than the quantities, so they pass with
   stale values (KE-rate 0 vs expected -7.6e-8).
6. **The `mu` target does not build on the three GMM-based branches,** with either nvfortran or
   gfortran. `HexMesh_ComputeLocalGradientNS` uses `NSGradientVariables_selector` and `Q_grad_NS`,
   which do not exist in the `-DMULTIPHASE` build. So `Multiphase/EntropyConservingTest` from
   their CI list cannot run.
7. **`GMM_develop`'s `CI_serial_GPU.yml` is byte-identical to `develop`'s and has no
   shock-capturing case.** For E.1 I ran its full NS list plus the three shock-capturing cases in
   the tree (`CylinderGMM`, `ForwardFacingStepSVV`, `TaylorGreenSVVLES`). All three are commented
   out in `CI_parallel_NS.yml`.
8. **C:** `!$acc exit data delete(sem)` is not needed for a clean exit. Without it, `sem`'s 10 KB device
   copy is never freed, but no run crashes or reports an error at shutdown, and the context teardown
   reclaims it. The device-allocation trace shows 7.2k other allocations (8.4 MB) also unreleased at
   exit, from unbalanced `enter data`/`exit data` pairs in `HexMesh_CreateDeviceData` (for example
   `elements(:)%geom%x` is copied in twice). memcheck could not finish shutdown within 45 minutes.
9. **The multiphase solver has the same `sem` issue as C, and more.** `MultiphaseSolver/main.f90`
   does `!$acc enter data copyin(sem)` but never calls `ExitDeviceData` or deletes `sem`.
10. **A build hazard: a full disk can produce a broken binary while `make` reports success.** The
    nvfortran device link writes a very large assembly file (about 2.5 M lines) to `$TMPDIR`. When
    the disk filled during the first `fix/gpu-port-develop` build, the assembler only warned
    (`end of file not at end of a line`). `make` still exited 0 and printed "MU - SUCCESFULLY
    COMPILED", but the binary had a truncated device image: a 12.8 MB `.data` section instead of
    40 MB. I relinked it with `TMPDIR=/dev/shm`. All binaries used below have complete images.
11. **Timing on this laptop is dominated by thermal throttling.** The session logged
    `nvidia-smi` every 2 s. Across the 2012 samples with the GPU busy (utilisation ≥ 50%), the
    temperature averaged 91 °C, `SW Thermal Slowdown` was active in every sample, and the SM
    clock averaged 216 MHz, against a maximum of 2100. 99% of busy samples were at 300 MHz or
    below. Absolute efficiencies here are therefore several times worse than this GPU can do, and
    they drift: the same Cylinder case measured 0.26 and then 0.99 s/(MDOF·iter) about 35 minutes
    apart. For comparisons between branches in A, see the r2 repetition and the controlled pass.
12. **Tooling issues.** The `compute-sanitizer` wrapper in HPC SDK 26.3 `compilers/bin` fails
    ("not available in this installation"), so I called
    `cuda/13.1/compute-sanitizer/compute-sanitizer` directly. After a device fault, the OpenACC
    runtime under the sanitizer loops printing `Failing in Thread:1`. Memcheck is also very slow
    on this code: a 512-element, 2-step run got through the time loop but did not finish within
    45 minutes. That case makes 54k separate device allocations, one per `enter data` of each
    element and face component.

## Method

- **Worktrees.** One git worktree per branch from a blobless clone of the fork. Disk space was
  short (3.9 GB free), so the checkouts are sparse: they leave out the nine
  `Solver/test/**/*_pAdaptationRL` directories (about 110 MB each) and `Multiphase/Pipe`, except
  the one mesh that `Multiphase/EntropyConservingTest` reads. Nothing else is missing.
- **Solver build.** `make ns mu COMPILER=nvfortran COMM=SERIAL ENABLE_THREADS=NO` with the local
  cc86-only edit to `Makefile.in`. On the GMM branches only `ns` builds (item 6).
- **Problem files.** `make COMPILER=nvfortran` fails because it also links the
  nssa/ins/ch libraries, which were not built. I used `make ns` or `make mu` with
  `COMPILER=nvfortran COMM=SERIAL ENABLE_THREADS=NO`, which is what the CI does.
- **Comparisons.** "Bitwise" means every number in the full-precision monitor files under
  `RESULTS/` is textually identical: `*.residuals` without the two wall-clock columns, plus
  `*.surface`, `*.probe` and `*.volume`. Otherwise I give the largest relative difference.
- **A's two repetitions.** A ran twice, interleaving develop and fix case by case. Repetition r1
  partly overlapped with other GPU jobs I started (B and E), and time-slicing makes the many
  small synchronous `enter data` transfers in `CreateDeviceData` very slow. So r1 wall times are
  not usable; r2 ran alone. Correctness is unaffected either way.
- **Scratch cases.** B, C and D use copies of existing cases with the one change described in each
  section. They are not committed.
- **Raw data.** The logs and monitor files of every run are kept locally and not pushed.

## A. No regressions: `fix/gpu-port-develop` against `develop`

All 17 cases that are not commented out in `develop`'s `CI_serial_GPU.yml` (16 NS, 1 MU). Each
ran twice per branch (r1, r2), interleaved develop/fix case by case. "Last residuals" is the final
line of `RESULTS/*.residuals`, which is identical on both branches.

| Case | Asserts develop | Asserts fix | Last residuals (cont, x, y, z, energy) | develop vs fix | GPU repeatability (dev r1/r2, fix r1/r2) |
| --- | --- | --- | --- | --- | --- |
| NavierStokes/Cylinder | 9/9 | 9/9 | it 100: 8.8131E+00 1.7609E+01 1.9038E-01 2.4301E+01 2.4064E+02 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderWALE | 8/8 | 8/8 | it 100: 7.9688E+00 1.6312E+01 2.2119E-01 2.1313E+01 2.1801E+02 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderVreman | 8/8 | 8/8 | it 100: 8.7427E+00 1.7470E+01 1.8964E-01 2.4032E+01 2.3873E+02 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderChandrasekarRoe | 8/8 | 8/8 | it 100: 9.2920E+00 2.4258E+01 2.3885E-01 2.8435E+01 2.5303E+02 | bitwise | bitwise / bitwise |
| NavierStokes/IBM_Cylinder | 6/6 | 6/6 | it 20: 1.2170E+02 6.7209E+02 1.0498E+02 6.0138E+01 6.2739E+03 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderEntropyConservingCentral | 8/8 | 8/8 | it 100: 2.2588E+01 5.1291E+01 9.0349E-01 4.6667E+01 6.8866E+02 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderRoePikePirozzoli | 8/8 | 8/8 | it 100: 8.9887E+00 2.4665E+01 2.3719E-01 2.7416E+01 2.4544E+02 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderKennedyGruberLaxFriedrichs | 8/8 | 8/8 | it 100: 9.2720E+00 2.3906E+01 2.4942E-01 2.6933E+01 2.5384E+02 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderMorinishiLowDissipationRoe | 8/8 | 8/8 | it 100: 1.2013E+01 2.3168E+01 4.1693E-01 2.9047E+01 3.6133E+02 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderDucrosMatrixDissipation | 8/8 | 8/8 | it 100: 9.4136E+00 2.4425E+01 2.3223E-01 2.7442E+01 2.5767E+02 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderViscousStandard | 8/8 | 8/8 | it 100: 1.5134E+01 3.8226E+01 2.3010E-01 2.5480E+01 3.9242E+02 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderRusanovStandard | 8/8 | 8/8 | it 100: 9.2676E+00 2.0571E+01 2.6016E-01 2.4346E+01 2.5288E+02 | bitwise | bitwise / bitwise |
| NavierStokes/CylinderUdissStandard | 8/8 | 8/8 | it 100: 2.0561E+01 5.3285E+01 7.9875E-01 7.0811E+01 6.1733E+02 | bitwise | bitwise / bitwise |
| NavierStokes/Cylinderssprk33 | 8/8 | 8/8 | it 100: 9.2149E+00 2.4491E+01 2.3642E-01 2.8737E+01 2.5079E+02 | bitwise | bitwise / bitwise |
| NavierStokes/Cylinderssprk43 | 8/8 | 8/8 | it 100: 9.2150E+00 2.4493E+01 2.3642E-01 2.8738E+01 2.5079E+02 | bitwise | bitwise / bitwise |
| NavierStokes/LimiterTest | 8/8 | 8/8 | it 100: 7.4208E+01 2.0015E+01 1.7530E+00 5.0892E+01 5.1458E+01 | bitwise | bitwise / bitwise |
| Multiphase/EntropyConservingTest | 5/5 | 5/5 | it 20: 7.1079E+02 4.6255E+03 2.9389E+03 2.3916E+04 3.3733E+06 | bitwise | bitwise / bitwise |

**Result: as expected.** Every case passes all its asserts on both branches. `develop` and `fix`
are bitwise identical in every monitor file. Each branch is also bitwise reproducible from r1 to
r2. None of the six changes (Face_Assign deep copy, NodalStorage mapping, ActuatorLine guard,
strong-form sharp fluxes, OpenMP-only edits, multiphase `"source"` monitor) changes a GPU result
in these cases.

### Solver efficiency and wall time

"Solver efficiency" is in s/(10⁶ DOF·iteration), from the `Solver efficiency:` line of each run.
r1 overlapped with other GPU jobs and is not usable for timing. r2 ran alone but on a GPU that
was already thermally throttled.

| Case | Efficiency develop r1 / r2 | Efficiency fix r1 / r2 | Wall develop r1 / r2 (s) | Wall fix r1 / r2 (s) |
| --- | --- | --- | --- | --- |
| NavierStokes/Cylinder | 2.558E-01 / 9.951E-01 | 2.986E-01 / 9.949E-01 | 8.26 / 17.80 | 8.63 / 17.85 |
| NavierStokes/CylinderWALE | 4.203E-01 / 1.246E+00 | 4.310E-01 / 1.244E+00 | 10.44 / 20.82 | 10.93 / 20.67 |
| NavierStokes/CylinderVreman | 6.076E-01 / 1.151E+00 | 7.121E-01 / 1.152E+00 | 14.12 / 19.75 | 15.43 / 19.66 |
| NavierStokes/CylinderChandrasekarRoe | 1.284E+00 / 1.607E+00 | 1.319E+00 / 1.607E+00 | 22.11 / 25.08 | 22.55 / 25.18 |
| NavierStokes/IBM_Cylinder | 2.656E+00 / 2.086E+00 | 4.129E+00 / 2.089E+00 | 47.99 / 37.54 | 57.97 / 38.49 |
| NavierStokes/CylinderEntropyConservingCentral | 3.389E+00 / 1.667E+00 | 3.893E+00 / 1.666E+00 | 51.45 / 25.41 | 64.03 / 25.33 |
| NavierStokes/CylinderRoePikePirozzoli | 2.662E+00 / 1.160E+00 | 2.915E+00 / 1.161E+00 | 45.51 / 19.69 | 48.98 / 19.57 |
| NavierStokes/CylinderKennedyGruberLaxFriedrichs | 2.518E+00 / 1.092E+00 | 1.766E+00 / 1.093E+00 | 44.01 / 18.69 | 28.91 / 18.92 |
| NavierStokes/CylinderMorinishiLowDissipationRoe | 2.290E+00 / 1.411E+00 | 3.215E+00 / 1.412E+00 | 34.89 / 22.68 | 46.31 / 22.26 |
| NavierStokes/CylinderDucrosMatrixDissipation | 2.504E+00 / 1.282E+00 | 2.921E+00 / 1.282E+00 | 45.08 / 21.18 | 44.67 / 21.31 |
| NavierStokes/CylinderViscousStandard | 2.320E+00 / 1.181E+00 | 1.911E+00 / 1.181E+00 | 40.94 / 19.95 | 30.46 / 19.97 |
| NavierStokes/CylinderRusanovStandard | 2.918E+00 / 1.797E+00 | 2.931E+00 / 1.797E+00 | 42.61 / 27.43 | 42.70 / 27.61 |
| NavierStokes/CylinderUdissStandard | 6.803E-01 / 4.206E-01 | 6.786E-01 / 4.216E-01 | 15.54 / 10.64 | 15.69 / 10.78 |
| NavierStokes/Cylinderssprk33 | 2.735E+00 / 1.605E+00 | 2.867E+00 / 1.605E+00 | 40.63 / 25.00 | 323.30 / 24.93 |
| NavierStokes/Cylinderssprk43 | 3.643E+00 / 2.110E+00 | 3.626E+00 / 2.642E+00 | 280.77 / 31.42 | 68.57 / 37.76 |
| NavierStokes/LimiterTest | 3.471E+00 / 1.630E+00 | 1.746E+00 / 2.139E+00 | 258.83 / 27.21 | 92.67 / 33.01 |
| Multiphase/EntropyConservingTest | 1.464E+00 / 1.887E+00 | 1.324E+00 / 1.421E+00 | 85.65 / 90.78 | 85.37 / 83.80 |

In r2, 14 of 17 cases agree between branches within 0.25% in efficiency. The other three differ
by 25–31% in both directions: fix is 25% slower on `Cylinderssprk43` and 31% slower on
`LimiterTest`, but 25% faster on the multiphase case. Those three were the last cases of r2, with
the GPU at 84–92 °C and its SM clock mostly at 210 MHz. To check, I repeated them, plus
`Cylinder` as a control. Before each run the GPU rests until it is at or below 65 °C or 90 s
have passed. In practice it never cooled that far: it loses about 1 °C per 20 s at idle, and the
desktop keeps it busy. So every run gets the same 90 s rest. The branch order is reversed in the
second repetition, and only these runs used the GPU during the pass.

| Case | develop r1 | develop r2 | fix r1 | fix r2 | fix / develop (mean) |
|---|---|---|---|---|---|
| Cylinder | 3.012e-01 | 2.342e-01 | 3.268e-01 | 2.351e-01 | 1.049 |
| Cylinderssprk43 | 4.584e-01 | 4.397e-01 | 4.202e-01 | 4.356e-01 | 0.953 |
| LimiterTest | 2.839e-01 | 3.034e-01 | 2.843e-01 | 2.981e-01 | 0.992 |
| EntropyConservingTest | 6.153e-01 | 5.917e-01 | 1.248e+00 | 5.567e-01 | 1.495 |

Efficiency in s/(10⁶ DOF·iter). r1 ran develop first, r2 ran fix first. All 16 runs pass their
asserts.

**Verdict: the same efficiency within run-to-run noise, as expected.**
- The noise is larger than any gap between branches. The same branch varies by up to 22% between
  repetitions (develop `Cylinder` 0.301 → 0.234), and one fix multiphase run took twice as long as
  the other (1.248 vs 0.557).
- The sign of the develop/fix gap changes from case to case (fix/develop means 0.95–1.05 apart
  from the multiphase outlier) and follows run order. In r2, where fix ran first after the rest,
  fix was the same or faster in all four cases.
- Together with A's r2 (14 of 17 cases within 0.25%), this attributes no efficiency change to
  `fix/gpu-port-develop`.

## B. NodalStorage device mapping (`30d3f071`)

TaylorGreen has only periodic boundaries, so I first used a copy of `NavierStokes/Cylinder` (wall,
inflow and outflow). I replaced `Polynomial order = 3` with `Polynomial order i/j/k = 3/4/5` and
changed nothing else. Both GPU builds crashed, and the CPU build of horses3d-gpu gave NaN. Legacy
horses3d runs the same case, which shows the Cylinder variant hits a second problem, at
p-nonconforming faces. So I repeated B on a copy of `NavierStokes/TaylorGreen` with the same three
order lines and the structured `TaylorGreen8.mesh` (512 elements, the mesh
`TaylorGreenSVVLES` uses). TaylorGreen32 with these orders is 3.9 M DOF and does not fit in 6 GB.

| Case (orders 3/4/5) | Build | Result | Residual history (cont, x, y, z, energy) |
|---|---|---|---|
| Cylinder copy (`CylinderNSpol3`, 1864 el.) | `develop`, GPU | Crash at the first time step: `CUDA_ERROR_ILLEGAL_ADDRESS`. First faulting kernel (with `CUDA_LAUNCH_BLOCKING=1`): `HexMesh_ProlongSolToFaces`, `HexMesh.f90:986` | — |
| | `fix/gpu-port-develop`, GPU | Same crash, same kernel | — |
| | `develop`, CPU (gfortran) | Runs; NaN from iteration 1; asserts 1/9 | it 0: 8.346E+01 1.604E+02 5.084E+00 3.115E+02 2.369E+03; it 1–100: NaN |
| | legacy horses3d `0d444d212`, CPU | Runs normally | it 0: 8.346E+01 1.604E+02 5.084E+00 3.115E+02 2.369E+03<br>it 1: 7.107E+01 1.277E+02 3.823E+00 2.696E+02 2.003E+03<br>it 10: 2.249E+01 4.826E+01 8.173E-01 7.170E+01 6.398E+02<br>it 100: 1.184E+01 2.445E+01 2.190E-01 3.278E+01 3.177E+02 |
| TaylorGreen copy (`TaylorGreen8`, 512 el.) | `develop`, GPU | Crash at the first time step, same kernel `HexMesh_ProlongSolToFaces:986` | — |
| | `fix/gpu-port-develop`, GPU | Same crash, same kernel | — |
| | `develop`, CPU (gfortran) | Runs; asserts 0/8 (they are calibrated for TaylorGreen32, P=3) | see below |
| | legacy horses3d, CPU | Runs; matches the horses3d-gpu CPU run to 3.2e-10 (residuals) and 1.5e-12 (volume monitors) | same as row above |

CPU residual history for the anisotropic TaylorGreen8 case (both GPU builds crash before
iteration 1):

| it | continuity | x-mom | y-mom | z-mom | energy |
|---|---|---|---|---|---|
| 0 | 2.528E-03 | 1.263E-01 | 1.309E-01 | 2.484E-01 | 1.177E+00 |
| 1 | 1.867E-03 | 1.268E-01 | 1.287E-01 | 2.483E-01 | 9.980E-01 |
| 2 | 1.177E-03 | 1.274E-01 | 1.267E-01 | 2.483E-01 | 8.083E-01 |
| 5 | 3.480E-04 | 1.289E-01 | 1.248E-01 | 2.484E-01 | 6.844E-01 |
| 10 | 6.969E-04 | 1.311E-01 | 1.290E-01 | 2.487E-01 | 6.090E-01 |

**Verdict.** `develop` crashes, as expected. `fix/gpu-port-develop` crashes in the same kernel, so
B's expectation ("the fix branch matches the CPU to round-off") is not met. Mapping orders 4 and
5 (the commit's change) is probably necessary but not sufficient. Something else in the device
data or kernels still assumes Nx = Ny = Nz. I could not narrow it further: a memcheck run of
this case reported nothing within its 10-minute limit.

The Cylinder variant shows a separate bug that is not GPU-specific. Elements whose local axes are
rotated relative to their neighbours give faces with different orders on each side once
Nx≠Ny≠Nz. Legacy `Face_AdaptSolutionToFace` handles that with `projectionType` 1–3 and the
`Tset` interpolation matrices. The port's `Face_AdaptSolToFace` (`FaceClass.f90`) only copies,
looping over `NfLeft`/`NfRight` as if both sides had the face order. In the gfortran build this
corrupts the face states (NaN after one step); on the GPU it faults. p-adapted meshes go through
the same routine, so they are probably affected too (not tested here).

## C. Device copy of `sem` at shutdown

`develop`'s `NavierStokesSolver/main.f90` does `!$acc enter data copyin(sem)` (line 112) and
never deletes it. I tested the line below, added right after `call sem % mesh %
ExitDeviceData()` (not committed):

```fortran
      !$acc exit data delete(sem)
```

To exercise the shutdown path, a run must get past `UserDefinedFinalize`. A failing assert calls
`error stop 99`, which exits before the GPU cleanup. So in the two short scratch cases used here I
replaced that `error stop 99` with a `WRITE`. The case files in the repository are unchanged.

| Run on `develop` | Exit code | Printed after "I delete the data from the GPU" | `sem` device copy (`NV_ACC_NOTIFY=16`) | memcheck + leak check |
|---|---|---|---|---|
| The 16 NS cases of A, 2 repetitions each | 0 | nothing | — | — |
| `Cylinder`, 5 steps | 0 | nothing | — | Stopped at its 40-minute limit with nothing reported (program output was buffered, so how far it got is unknown) |
| `TaylorGreen` on TaylorGreen8, 2 steps | 0 | nothing | 10240 B allocated at `main.f90:112`, **never deleted or freed** before exit | Stopped at its 45-minute limit, after the time loop had finished; no errors reported up to then; leak summary not reached |
| Same two cases + `exit data delete(sem)` | 0 | nothing | Allocated at line 112, deleted and freed at line 212 | TaylorGreen8 only: same as above (stopped at the limit after the time loop, no errors reported) |

With and without the line, results are bitwise identical (5-step Cylinder: all monitor files).
The allocation trace also shows that `sem` is one of many: at exit, `develop` still holds 7188
device allocations (8.4 MB) for the 512-element case. They come from unbalanced pairs in
`HexMesh_CreateDeviceData`/`ExitDeviceData` (`HexMesh.f90`):
- `faces(:)%storage(1:2)%rho` (lines 4543–4544),
- `faces(:)%geom` and `faces(:)%geom%x` (4545–4546),
- `elements(:)%storage%S_NS` (4464),
- `elements(:)%geom%x` (4468), which is copied in twice and deleted once. `fix/gpu-port-develop`
  has the same duplicate.

**Verdict: the line is not needed for correctness, but it is the right cleanup.** Without it, the
device copy of `sem` is simply reclaimed when the CUDA context is destroyed at exit. No run
crashed, printed an error at shutdown, or returned a non-zero exit code, and no invalid access was
reported. The line removes exactly one of about 7.2k unreleased device allocations; the others
come from the unbalanced pairs above. It would matter only if the solver were re-initialised in
one process, or for leak-checking tools. `MultiphaseSolver/main.f90` has the same `enter data
copyin(sem)` (line 104) and does no device cleanup at all (no `ExitDeviceData`).

## D. Stale volume monitors on the GPU

`TaylorGreen` with the TaylorGreen32 mesh does not fit on this GPU. `develop` runs out of memory
in `HexMesh_CreateDeviceData` (`cuMemAlloc` returns `CUDA_ERROR_OUT_OF_MEMORY` at
`HexMesh.f90:4523`; about 2.1 M DOF). The CPU run of the real case (TaylorGreen32, P=3) passes
8/8. I compared GPU and CPU on the identical control file with the TaylorGreen8 mesh (P=3,
32 768 DOF). Only the mesh changed; the asserts fail on both because they are calibrated for
TaylorGreen32.

| it | KE, CPU | KE, GPU | KE rate, CPU | KE rate, GPU | Enstrophy, CPU | Enstrophy, GPU |
|---|---|---|---|---|---|---|
| 0 | 1.2499999999999915E-01 | 1.2499999999999920E-01 | -4.3030E-04 | 0 | 3.7500072710E-01 | 0 |
| 1 | 1.2499903466089549E-01 | 1.2499999999999920E-01 | -4.2163E-04 | 0 | 3.7499865673E-01 | 0 |
| 2 | 1.2499806909212707E-01 | 1.2499999999999920E-01 | -4.2172E-04 | 0 | 3.7499625013E-01 | 0 |
| 5 | 1.2499517199562561E-01 | 1.2499999999999920E-01 | -4.2176E-04 | 0 | 3.7499138685E-01 | 0 |
| 10 | 1.2499034435383351E-01 | 1.2499999999999920E-01 | -4.2160E-04 | 0 | 3.7499113538E-01 | 0 |

The residuals, which are computed on the device, agree with the CPU to 8e-10 relative at every
iteration. So the solution is right and only the host-side monitors are wrong.

- **Stale? Yes, and frozen rather than lagging.** `ScalarVolumeIntegral` reads host data. Host
  `Q` is written only by `HexMesh_UpdateHostData`, which is called from `SaveSolution`. In this
  case that happens once, for the initial-condition file, and again after the asserts. Host
  `QDot` is never copied back at all; `UpdateHostData` does not include it. Host
  `U_x`/`U_y`/`U_z` were copied back during that initial save, before the device had computed
  any gradient, so they are zero. The result: KE equals its initial value, and KE rate and
  enstrophy are exactly 0.
- **Which iteration do the asserts read? The last one (iteration 10).** `Monitor_UpdateValues`
  fills buffer lines 1..11 (iterations 0..10). The forced flush after the time loop
  (`Monitor_WriteToFile(force=.true.)`) then sets `values(:,1) = values(:,no_of_lines)`.
  `UserDefinedFinalize` runs after that and before the final `SaveSolution`. The CPU run
  confirms it: iteration 10 of the TaylorGreen32 run gives KE 0.12499758737115484, which matches
  the expected 0.12499758737106952 to 8.5e-14.
- **Would the asserts notice? Yes for TaylorGreen, no for TaylorGreenSVVLES.** On the GPU,
  TaylorGreen would report KE ≈ 0.12500000000006 (the initial value) against the expected
  0.12499758737106952, a difference of 2.4e-6 with tolerance 1e-11. KE rate would be 0 against
  -4.28e-4, and enstrophy 0 against 0.375. That is 3 failures out of 8. But TaylorGreen is
  commented out of `CI_serial_GPU.yml` and does not fit on a 6 GB card, so nothing currently
  runs it on a GPU. `TaylorGreenSVVLES` checks the same kind of monitors with tolerance 1e-7.
  There `SC_detect` refreshes host `Q` every step, so KE is current, but KE rate is still 0 on
  the GPU at every iteration. The assert passes anyway, because 1e-7 is larger than the expected
  value (-7.6e-8); even the CPU's -2.4e-8 passes.

## E. GMM branches

### E.1 `GMM_develop` vs `fix/gpu-port-GMM`

`GMM_develop`'s `CI_serial_GPU.yml` is identical to `develop`'s and has no shock-capturing case.
I ran its whole NS list. Its multiphase case cannot be built (unexpected result 6). I added the
three shock-capturing cases in the tree, all single-process (CI ran them with `mpiexec -n 8` on
CPU, and they are commented out there).

| Case | Asserts GMM_develop | Asserts fix/gpu-port-GMM | Last residuals (cont, x, y, z, energy) | GMM vs fix | Efficiency GMM / fix | Wall GMM / fix (s) |
|---|---|---|---|---|---|---|
| NavierStokes/Cylinder | 9/9 | 9/9 | it 100: 8.8131E+00 1.7609E+01 1.9038E-01 2.4301E+01 2.4064E+02 | bitwise | 9.204E-01 / 1.324E+00 | 17.39 / 22.06 |
| NavierStokes/CylinderWALE | 8/8 | 8/8 | it 100: 7.9688E+00 1.6312E+01 2.2119E-01 2.1313E+01 2.1801E+02 | bitwise | 1.254E+00 / 1.255E+00 | 22.93 / 21.28 |
| NavierStokes/CylinderVreman | 8/8 | 8/8 | it 100: 8.7427E+00 1.7470E+01 1.8964E-01 2.4032E+01 2.3873E+02 | bitwise | 1.160E+00 / 1.160E+00 | 20.37 / 20.24 |
| NavierStokes/CylinderChandrasekarRoe | 8/8 | 8/8 | it 100: 9.2920E+00 2.4258E+01 2.3885E-01 2.8435E+01 2.5303E+02 | bitwise | 1.605E+00 / 1.606E+00 | 26.00 / 25.84 |
| NavierStokes/IBM_Cylinder | 6/6 | 6/6 | it 20: 1.2170E+02 6.7209E+02 1.0498E+02 6.0138E+01 6.2739E+03 | bitwise | 2.092E+00 / 2.092E+00 | 40.23 / 40.66 |
| NavierStokes/CylinderEntropyConservingCentral | 8/8 | 8/8 | it 100: 2.2588E+01 5.1291E+01 9.0349E-01 4.6667E+01 6.8866E+02 | bitwise | 1.671E+00 / 1.670E+00 | 26.37 / 26.56 |
| NavierStokes/CylinderRoePikePirozzoli | 8/8 | 8/8 | it 100: 8.9887E+00 2.4665E+01 2.3719E-01 2.7416E+01 2.4544E+02 | bitwise | 1.164E+00 / 1.164E+00 | 20.33 / 20.54 |
| NavierStokes/CylinderKennedyGruberLaxFriedrichs | 8/8 | 8/8 | it 100: 9.2720E+00 2.3906E+01 2.4942E-01 2.6933E+01 2.5384E+02 | bitwise | 1.097E+00 / 1.097E+00 | 19.59 / 19.91 |
| NavierStokes/CylinderMorinishiLowDissipationRoe | 8/8 | 8/8 | it 100: 1.2013E+01 2.3168E+01 4.1693E-01 2.9047E+01 3.6133E+02 | bitwise | 1.418E+00 / 1.418E+00 | 23.60 / 23.41 |
| NavierStokes/CylinderDucrosMatrixDissipation | 8/8 | 8/8 | it 100: 9.4136E+00 2.4425E+01 2.3223E-01 2.7442E+01 2.5767E+02 | bitwise | 1.286E+00 / 1.286E+00 | 22.28 / 22.11 |
| NavierStokes/CylinderViscousStandard | 8/8 | 8/8 | it 100: 1.5134E+01 3.8226E+01 2.3010E-01 2.5480E+01 3.9242E+02 | bitwise | 1.181E+00 / 1.179E+00 | 21.12 / 20.74 |
| NavierStokes/CylinderRusanovStandard | 8/8 | 8/8 | it 100: 9.2676E+00 2.0571E+01 2.6016E-01 2.4346E+01 2.5288E+02 | bitwise | 1.795E+00 / 1.799E+00 | 28.44 / 28.19 |
| NavierStokes/CylinderUdissStandard | 8/8 | 8/8 | it 100: 2.0561E+01 5.3285E+01 7.9875E-01 7.0811E+01 6.1733E+02 | bitwise | 4.211E-01 / 4.212E-01 | 11.68 / 11.36 |
| NavierStokes/Cylinderssprk33 | 8/8 | 8/8 | it 100: 9.2149E+00 2.4491E+01 2.3642E-01 2.8737E+01 2.5079E+02 | bitwise | 2.098E+00 / 1.605E+00 | 31.47 / 25.59 |
| NavierStokes/Cylinderssprk43 | 8/8 | 8/8 | it 100: 9.2150E+00 2.4493E+01 2.3642E-01 2.8738E+01 2.5079E+02 | bitwise | 2.104E+00 / 2.105E+00 | 31.64 / 31.76 |
| NavierStokes/LimiterTest | 8/8 | 8/8 | it 100: 7.4208E+01 2.0015E+01 1.7530E+00 5.0892E+01 5.1458E+01 | bitwise | 1.332E+00 / 1.334E+00 | 22.56 / 22.54 |
| NavierStokes/CylinderGMM | 5/5 | 5/5 | it 10: 1.3688E+02 4.4483E+01 3.2590E-04 1.6596E+02 1.5692E+02 | bitwise | 4.267E+00 / 4.159E+00 | 20.04 / 19.28 |
| NavierStokes/ForwardFacingStepSVV | crash (rc=1) | crash (rc=1) | — (illegal address in the first time step) | same crash | — / — | 7.83 / 8.27 |
| NavierStokes/TaylorGreenSVVLES | 3/8 | 3/8 | it 10: 3.5400E-05 1.2688E-01 1.2697E-01 2.5045E-01 6.1439E-01 | bitwise | 2.068E+00 / 2.093E+00 | 16.04 / 16.51 |

The efficiency and wall-time columns are indicative only: E ran on the throttled GPU, partly
alongside short debugging runs.

The two branches are bitwise identical on every case that runs, so `fix/gpu-port-GMM` changes no
GPU result. The `TaylorGreenSVVLES` failures and the `ForwardFacingStepSVV` crash are already on
`GMM_develop`.

- **`ForwardFacingStepSVV`.** Illegal address in the first time step on both branches. Without
  synchronous launches, the error surfaces at a stream sync in
  `TimeDerivative_ComputeArtificialViscosity`. With `CUDA_LAUNCH_BLOCKING=1 NV_ACC_NOTIFY=1`, the
  faulting kernel is the sixth one launched, `HexMesh_ComputeLocalGradientNS`
  (`HexMesh.f90:5716`). This case uses `Sensor variable = grad rho` and P=7. `Q_grad_NS` is mapped in `CreateDeviceData`, so the cause is not obvious; memcheck did not
  report anything in the time I gave it (see "Not run").
- **`CylinderGMM`.** Passes 5/5 on both branches.

### E.2 / E.3 `TaylorGreenSVVLES` against the CPU

| Build | Asserts | x-mom residual (it 10) | Energy residual (it 10) |
|---|---|---|---|
| CPU reference, `GMM_develop` (given) | 8/8 | 0.127069145556453 (expected) | 0.628947793858187 (expected) |
| CPU, `GMM_develop`, gfortran, this machine | 8/8 | 0.12706914501203939 | 0.62894780494986635 |
| GPU, `GMM_develop` | 3/8 | 0.12687912200904428 | 0.61439358352602280 |
| GPU, `fix/gpu-port-GMM` | 3/8 | 0.12687912200904428 (bitwise = GMM) | 0.61439358352602280 |
| GPU, `GMM_develop` + SVV patch below | **8/8** | 0.12706914515095963 | 0.62894779667412681 |
| CPU reference, `discuss` (given) | 3/8 | 0.12704234777396151 | 0.62824891369909053 |
| GPU, `discuss/legacy-shared-bugs` | 3/8 | 0.12676980803612661 | 0.61287630270384841 |
| GPU, `discuss` + SVV patch below | 3/8 (same 5 failures as CPU) | 0.12704234713568421 | 0.62824890537944056 |

**Does the GPU reproduce the CPU? No, on either branch, as the code stands.** It does once the
SVV host path is fixed. Iteration-by-iteration comparison on `GMM_develop`:
- At iteration 0 the GPU and CPU agree (x-momentum relative difference 6e-9).
- From iteration 1 they diverge (0.12572 vs 0.12647), and the gap reaches 2.3% in energy by
  iteration 10.
- On the GPU, kinetic energy rises slightly (0.125 → 0.12500000000187), while on the CPU it
  decays (→ 0.12499999989532).

The SVV method sets `SCdev_onDevice = .false.`, so `TimeDerivative_ComputeArtificialViscosity`
takes its host branch. That branch's own comment says it "needs Q and the gradients pulled back
first", but nothing pulls them back. `SC_detect` refreshes host data once per time step, so every
RK stage after the first uses start-of-step values. Also, only the face `AviscFlux` is pushed to
the device; the element `AviscContravariantFlux` computed on the host never reaches the device
volume term.

This experiment patch (not committed) fixes both. With it, `GMM_develop` passes 8/8. At every
iteration it matches the CPU within 1.3e-8 in the momentum and energy residuals, within 1.2e-7 in
the much smaller continuity residual, and within 1e-13 in the KE and SVV monitors:

```diff
@@ TimeDerivative_ComputeArtificialViscosity, SVV (host) branch
+            !$acc wait
+            do eID = 1, size(mesh % elements)
+               !$acc update self(mesh % elements(eID) % storage % Q, mesh % elements(eID) % storage % U_x, mesh % elements(eID) % storage % U_y, mesh % elements(eID) % storage % U_z)
+            end do
             do eID = 1, size(mesh % elements)
                call ShockCapturingDriver % ComputeViscosity(mesh, mesh % elements(eID), &
                                     mesh % elements(eID) % storage % AviscContravariantFlux)
             end do
+            do eID = 1, size(mesh % elements)
+               !$acc update device(mesh % elements(eID) % storage % AviscContravariantFlux)
+            end do
```

It costs a full device→host copy of `Q` and the gradients at every stage, so it is a diagnosis,
not a proposed fix. The real fix is to port the SVV filter to the device.

## F. LimiterTest (`develop`, GPU)

| Run | Asserts | Last residuals, it 100 (cont, x, y, z, energy) | Solver efficiency, s/(MDOF·iter) |
|---|---|---|---|
| r1 (contended, see Method) | 8/8 pass | 7.4208378015223573E+01 2.0014725058013077E+01 1.7529533584673582E+00 5.0892385073123961E+01 5.1458096712390820E+01 | 3.471E+00 |
| r2 | 8/8 pass | identical (bitwise) | 1.630E+00 |

`fix/gpu-port-develop` gives bitwise the same results. `GMM_develop` and `fix/gpu-port-GMM`
(bitwise identical to each other) agree with `develop` to 2.8e-12 in the residuals. They are not
bitwise identical, because `GMM_develop` carries other changes.

## Not run

- **MPI or multi-GPU cases:** none of the requested cases needs them. The shock-capturing cases
  CI ran with `mpiexec -n 8` were run as single processes.
- **`TaylorGreen` (TaylorGreen32) on the GPU:** out of device memory on 6 GB. D used TaylorGreen8.
- **`Multiphase/EntropyConservingTest` on the three GMM-based branches:** `mu` does not compile.
- **memcheck root-cause runs for the B and `ForwardFacingStepSVV` crashes:** neither reported
  anything within its time limit (10 and about 4 minutes), so I stopped them. The faulting
  kernels above come from `CUDA_LAUNCH_BLOCKING=1 NV_ACC_NOTIFY=1` runs instead.
