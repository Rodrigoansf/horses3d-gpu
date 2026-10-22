# E-verify: adversarial check of review claims C1-C8 (code reading only)

Trees: GPU PR `gpu-wt/rev145` (paths below are under `Solver/src/` unless stated), legacy PR `gpu-wt/rev387`.
Nothing was built or run.

| claim | verdict |
|---|---|
| C1 angle from node 1, r = 0 | **confirmed**, and worse under MPI (per-rank override) |
| C2 master by hash order, one global angle | **confirmed**; MPI sign logic consistent only for one pair; per-rank recompute makes the angle rank-dependent |
| C3 matching tolerances | **confirmed**, with nuance: strict failure is loud, not silent |
| C4 FluidData re-export not needed | **refuted**: HexMesh.f90 compiles only through it (also on dumbSRF) |
| C5 hook coverage | **partly**: NS time-derivative paths are covered; gaps in nssa (legacy), legacy shock-capturing AviscFlux, analytical Jacobian; rotate-back loop bounds wrong for non-conforming/anisotropic faces |
| C6 legacy analytical Jacobian | **confirmed** (NS+IP or Euler, implicit); the same code is in the GPU tree but its prolongation is a no-op there |
| C7 disabled = no runtime cost | **confirmed** (only `CountRotaryFaces` runs unguarded, once at start-up) |
| C8 OpenMP barriers | **confirmed**: no race added, in either tree |

---

## C1. First matched node on the axis -> angle 0 — CONFIRMED

- `libs/mesh/HexMesh.f90:690-704`: `x1 = node(face_i % nodeIDs(1))`, partner found among face j nodes, then
  `SetPeriodicAngle(SectorAngle(x1,x2))`. Nothing checks r(x1) > tol and nothing checks angle /= 0.
- `libs/rotation/RotationData.f90:138-150`: on the axis, x1 = x2 = the same point. That gives
  `atan2(0,0) - atan2(0,0)` = 0 with gfortran/libm (processor-dependent in the standard). The `anint` wrap
  keeps it at 0.
- Can such a face be matched? Yes. `CompareTwoNodesRevol` (`RotationData.f90:195-211`) gives r1 = r2 = 0
  exactly, and `AlmostEqual` has an absolute branch when either argument is 0 (`libs/foundation/Utilities.f90:125-130`).
  The axial coordinate then matches the same axis node. The other 3 nodes match normally. So the face pairs fine,
  and only the angle is wrong.
- Realistic meshes: an O-grid or butterfly sector of a pipe, nozzle or cone. The core block's corner sits on the
  axis, and the core element's two periodic faces both contain that axis node (often the *same element* on both
  sides, which HORSES3D supports). Whether node 1 is the axis node depends on the face's local node order, so
  for such a face it is about a coin toss.
- Worse under MPI. `periodicAngleSet` is a local of each call (`HexMesh.f90:527,530`). Every rank re-runs
  `ConstructPeriodicFaces` on its partition (`Read_GMSH.f90:1521,3276`, `Read_SpecMesh.f90:893`, after
  `SyncPeriodicAngle` at `DGSEMClass.f90:302`). Each rank therefore overwrites the broadcast angle with the one
  from its own first local pair. A rank whose first local face has node 1 on the axis gets angle 0 even when
  root's angle was right. The comments at `HexMesh.f90:752-755` and `RotationData.f90:156` ("root rank only, first
  call") do not match the code.

## C2. Master side by zone order, one global angle — CONFIRMED (MPI part: partly)

- Master selection (`HexMesh.f90:541-568`). The outer loop takes the first zone (by index) with BC "periodic"
  that is not `toBeDeleted` as zIDPlus. Its partner is marked `toBeDeleted`. Face i (zIDPlus) becomes side 1 and
  face j becomes side 2 (`:685-686`). The control file cannot choose which zone is master.
- Zone order is hash order. `ZoneClass.f90:62-74` builds zones in `zoneNameDictionary % allKeys()` order.
  `FTDictionaryClass.f90:371-390` puts keys in bucket `b3hs_hash_key_jenkins(key, size)`, and `AllKeys`
  (`:633-678`) walks buckets 1..size, then each bucket's list in insertion order (`FTLinkedListClass.f90:301-320`
  appends). The dictionary has 8 buckets (`libs/foundation/SharedDictionaries.f90:17`). So the order depends on
  name hash and insertion order, not on the control file.
- One angle (C2 proper). The angle = `SectorAngle(master node, slave node)`, taken once per call from the first
  matched pair (`:690-704`). A second pair whose zIDPlus sits on the other side needs −angle but gets +angle.
  Every hook uses the single `rotationParams % periodicAngle` (`RotaryFaceRotations.f90:52,82,107,135,166,193`).
  Multi-patch periodic sides (several `Periodic` pairs per side, common with multi-block generators) hit this
  about half the time per pair.
- MPI sign. Sides are preserved from root's serial face: `MeshPartitioning.f90:280-311` gives dL side 1 and dR
  side 2, and `HexMesh.f90:2516-2537` sets the other side to `HMESH_NONE = 0` (`MeshTypes.f90:21`).
  `ReceivedSide` (`RotaryFaceRotations.f90:209-215`) is therefore consistent with `otherSide(thisSide)` in the
  gathers, and with one pair the sign is right (matches the runs). However:
  (a) with several pairs, the MPI faces of the "flipped" pair inherit the wrong sign;
  (b) the per-rank recompute (see C1) can leave different ranks with different angles: ±α, or 0 if no local pair
  on the read-partitioning path. Then the two ranks of one MPI rotary face rotate inconsistently;
  (c) possible but unverified: with SpecMesh/GMSH, non-root ranks insert zone names in *local* element order
  (`Read_SpecMesh.f90:842-847`), while root keeps the order from the full read. If the two names of a pair land
  in the same bucket, a rank can see master and slave swapped relative to root. Its local angle is then −α while
  its MPI faces keep root's sides, so even a single pair gets a wrong sign on that rank. HOPR inserts in
  file order (`Read_HDF5Mesh_HOPR.f90:676-681`), so it is consistent there.

## C3. Node-matching tolerances — CONFIRMED (nuanced)

- `AlmostEqual` (`Utilities.f90:110-139`): tolerance `2*epsilon`, relative when both values are nonzero and
  absolute when either is 0. `AlmostEqualRelax` (`:143-165`): `|a-b| <= 1e-4 * reference_length`.
- The translational `CompareTwoNodes` (`HexMesh.f90:803,820`) uses the same strict `AlmostEqual`. It compares
  coordinates that a translational periodic mesh carries as bit-identical copies (only the periodic coordinate
  changes). Rotary matching (`RotationData.f90:200-207`) compares r², which is recomputed from two independently
  rounded rotated coordinate pairs. Rounding of r·cosθ and r·sinθ plus the squaring and summing already gives an
  r² difference of order eps. Text mesh formats that truncate digits make it much larger. So rotary *is* more
  fragile. The axial coordinate is unchanged by the rotation, so that part is as robust as translational.
- Nuance: a strict-tolerance failure is **loud** ("Face … was not able to find a partner", `HexMesh.f90:743-747`).
  It is not a wrong result. The PR mesh passes with both tolerances.
- Relax (`RotationData.f90:249`). `|r1²−r2²| <= 1e-4·h` means `|Δr| <= 1e-4·h/(2r)`. That depends on units and on
  r/h: 20× tighter than intended at r/h = 10 and looser near the axis. The finding stands: compare r, not r².

## C4. FluidData re-export not needed — REFUTED

- `libs/physics/common/FluidData.f90:16` `use RotationData` (no `private`, so everything is re-exported).
- `libs/mesh/HexMesh.f90` imports nothing from RotationData directly. Its only route is `use FluidData`
  (`:18`, pre-existing). Yet `ConstructPeriodicFaces` uses `rotationParams`, `RotationAxisIndex`,
  `CompareTwoNodesRevol(Relax)`, `SetPeriodicAngle` and `SectorAngle` (`:555,658-662,688-703,716-720`, 20 uses).
  The other users import RotationData explicitly: `DGSEMClass.f90:105` (only), `RotaryFaceRotations.f90:16`
  (only; a private module, so it re-exports nothing), and `NavierStokesSolver/SpatialDiscretization.f90:19`.
  Legacy is the same (`rev387 HexMesh.f90:18`). Removing the re-export breaks the build of HexMesh.
- `upstream/dumbSRF` (`8fdada9a`): `FluidData.f90:16` has the same `use RotationData`, and `HexMesh.f90:18` relies
  on it the same way (26 uses). NoSlipWallBC, FreeSlipWallBC, RiemannSolvers_NS and BR1 import `RotationData`
  directly. So the re-export comes from the SRF branch, and only HexMesh needs it.
- Corrected finding 9: the re-export is load-bearing for HexMesh only. Add `use RotationData, only: ...` to
  HexMesh (or move the matching helpers to libs/mesh) and drop the re-export.

## C5. Hook coverage — PARTLY (gaps found)

Covered (prolong → rotate → flux → rotate back, lists matching):
- GPU: `ComputeTimeDerivative` (`NavierStokesSolver/SpatialDiscretization.f90:266-267`), `ComputeQDot`
  (`:480-498`, MPI `:521-531`) and `ComputeQDotHO` (`:819-826`, `:853-863`); BR1 (`EllipticBR1.f90:190,212,246`);
  BR2 and IP non-HO (`EllipticBR2.f90:193,245,283`; `EllipticIP.f90:259,308,343`). The GPU BR2/IP HO branch
  skips the gradient rotation but still rotates unStar back. That is *consistent*, because that branch prolongs
  nothing (local gradient and prolongation are commented out, `EllipticBR2.f90:165-179`, `EllipticIP.f90:232-250`)
  while unStar is recomputed from the (rotated) Q.
- Legacy: the main, HO (`HO_Elements`) and MLRK (`MLIter_eIDN`) variants of ComputeTimeDerivative
  (`:265-279`), `ComputeQDot` (`:486,526-528`), `QDotMLRK` (`:825,865-867`) and `QDotHO` (`:1154,1194-1196`).
  BR1 normal, MLRK and HO (`EllipticBR1.f90:238,267,305,337,366,404,474,503,541`), BR2 and IP with HO lists. In
  every case the rotation list equals the prolongation list.
- MPI: the received side is rotated after each gather, and the flux goes to the local side only
  (`computeMPIFaceFlux`, `BR1_ComputeMPIFaceAverage` project to `Sidearray` = local side). `GatherMPIFacesGradients`
  overwrites only U_x/y/z (`HexMesh.f90:1576-1586`), so Q is never rotated twice.
- FAS/multigrid child meshes: `ConstructPeriodicFaces` runs again, the flag is copied in `Face_Assign`
  (`FaceClass.f90:1047`), and the same hooked ComputeTimeDerivative is used. OK.
- `ComputeTimeDerivativeIsolated` is harmless:
  - GPU: `mesh % ProlongSolutionToFaces` is a no-op (body commented out, `HexMesh.f90:979-1027`), and
    `QDotIsolated` (`:1113-1210`) is element-local.
  - Legacy: it prolongs Q *and* gradients without rotation (`:368,379`) and leaves storage(2) unrotated.
    This is safe because the next full ComputeTimeDerivative re-prolongs everything. It would leak only if a
    partial (MixedRK HO / MLRK) evaluation followed directly; not seen in practice (TE estimation runs before
    integration; the SC TE sensor uses its own `coarseSem`).

Gaps (wrong results, no error):
1. **Legacy Spalart–Allmaras solver (`horses3d.nssa`).** It is built with `-DNAVIERSTOKES -DSPALARTALMARAS`
   (`NavierStokesSolverRANS/Makefile:50`; `libs/discretization/Makefile:109` builds DGSEMClass for nssa), so the
   guard `#if !defined(NAVIERSTOKES)` (`DGSEMClass.f90:266`, GPU `:247`) lets it through.
   `NavierStokesSolverRANS/SpatialDiscretization.f90:286` prolongs with no solution rotation and has no flux
   rotate-back. Meanwhile the shared BR1/BR2/IP hooks still fire (gradient rotation, unStar rotate-back, MPI
   solution rotation). The result is silently wrong and frame-inconsistent. On GPU the RANS path calls the no-op
   prolongation, so it is broken anyway (pre-existing). Fix: guard with
   `!defined(NAVIERSTOKES) || defined(SPALARTALMARAS)`.
2. **Legacy shock capturing (artificial viscosity / SVV).** `AviscFlux` is computed from element data in element
   2's frame (`ShockCapturing.f90:700-744`, `:951`). It is then averaged unrotated:
   `0.5*(storage(1)%AviscFlux + storage(2)%AviscFlux)` (`NavierStokesSolver/SpatialDiscretization.f90:1763`,
   MPI `:1855`). The momentum rows are mixed across frames. The GPU face flux does not use AviscFlux at all
   (pre-existing), so this is legacy only.
3. **Analytical Jacobian:** see C6.
4. **Rotate-back loop bounds (both trees).** `RotateBackRotaryFacesFlux` and `…GradientFlux` loop
   `j=0:Nf(2), i=0:Nf(1)` (`RotaryFaceRotations.f90:164,191`; legacy `:153,177`). But side-2 `FStar` and `unStar`
   are pointer-shaped `0:Nel(1),0:Nel(2)` with Nel = NelRight (`StorageClass.f90:1637,1646`; legacy
   `:1663,1671`). Their sizes differ from Nf when (a) the face is p-non-conforming (Nf = max, legacy
   p-adaptation or mixed orders), or (b) Nx≠Ny on the face with an axis-swapping face rotation 1,3,4,6
   (`FaceClass.f90:229-236`). In both cases some entries are rotated twice or not at all; the backing memory is
   large enough, so there is no crash in release builds, and a bounds error with `-fcheck`. The base code loops
   side 2 over NfRight/NelRight (`FaceClass.f90:556-558`). Q and U_x/y/z are Nf-shaped, so their rotations are fine.
5. Latent only: the legacy BR1 non-MLRK path rotates all of `elements_sequential`/`elements_mpi` even when
   `element_mask` skipped their prolongation (`EllipticBR1.f90:343-366`). That would double-rotate, but only
   multiphase passes masks, and multiphase is blocked by the guard.

Nothing else reads interior storage(2): the only other side-2 users are BC ghost states, wall functions,
GradientsStabilization (Cahn–Hilliard only) and other solvers that the guard blocks. No monitors, statistics or
IO read it.

## C6. Legacy AnalyticalJacobian — CONFIRMED

- `libs/timeintegrator/AnalyticalJacobian.f90:202` prolongs Q with **no** rotation, then `:220` calls
  `ViscousDiscretization % ComputeGradient`, whose hooks *do* rotate. The result is an inconsistent mix:
  unrotated Q, rotated side-2 gradients, unStar rotated back from a cross-frame jump. `:505-511/604-609` evaluate
  dF*/dq at (Q_L, unrotated Q_R), and the blocks never get the R(∓α) factors (dF₂/dq_R = R(+α)·∂F/∂q_R·R(−α)).
  MPI faces: `:440-442` gathers with no rotation (Euler), while for NS the MPI Q was rotated inside IP.
- NS support: yes, `#if defined(NAVIERSTOKES)` (`:136-271`). The viscous Jacobian exists only for IP
  (`EllipticIP.f90:796`); BR1/BR2 hit `error stop` (`EllipticDiscretizationClass.f90:339-349`).
- Reachable: NS+IP or Euler, implicit (BDF/Rosenbrock/FAS-implicit) with the analytical Jacobian
  (`GenericLinSolverClass.f90:114`). Impact: as a Newton preconditioner it only costs convergence. Where the matrix
  is the operator (e.g. Rosenbrock stages) it can cost accuracy. The guard does not stop this case.
- GPU tree: same code (`AnalyticalJacobian.f90:202,220`), but the prolongation is a no-op there, so it is
  broken regardless (pre-existing).

## C7. Disabled = no runtime cost — CONFIRMED

- Each hook returns on `if (.not. rotationParams % periodicEnabled) return` before any loop, `!$acc` or
  `!$omp` construct (`RotaryFaceRotations.f90:38,68,99,127,156,183`). In `RotateBackRotaryFacesFlux` the return
  comes *before* `!$omp barrier` (`:183-184`), and the flag is a shared module variable, so all threads take the
  same branch (no deadlock).
- The check reads the host copy, so there is no device synchronisation. No directives were added at call sites
  (checked in `gpu145.diff`).
- Unguarded: `DescribeRotation(CountRotaryFaces(mesh))` (`NavierStokesSolver/SpatialDiscretization.f90:82`,
  legacy `:81`). It runs one loop over faces and 2 `mpi_allreduce` once at start-up, on all ranks (collective-safe:
  inside `.not. child`, which every rank evaluates the same way). Other costs are also start-up only:
  `InitializeRotationFromControl` normalisation and `!$acc update device`, the extra logical in the partition
  send and in the `.partitioning` file, and the matching branches.

## C8. OpenMP — CONFIRMED (no race added)

- All call sites sit inside the `!$omp parallel` of ComputeTimeDerivative (GPU `:265-318`, legacy `:265-332`).
  None is inside a `single` or a worksharing construct, so the orphaned `!$omp do` and the `!$omp barrier` are
  legal.
- Prolong → rotate: the prolongation loops end with `!$omp end do` and an implicit barrier (GPU
  `HexMesh.f90:1050/1061` and `1104` etc.; legacy `:1041,1064,1084`, BR2/IP element loops
  `EllipticBR2.f90:176/196`, `EllipticIP.f90:242/261`, BR1 `:266,304,365,403,502,540`).
- Rotate → flux: each rotation ends with `!$omp end do` (barrier). The MPI rotations follow `!$omp end single`
  (barrier).
- Flux → rotate back: the flux loop is `nowait` (GPU `:496,824`; legacy `:484,823,1152`), so the explicit
  `!$omp barrier` is required and present (`:184`). The gradient-flux rotate-backs follow boundary loops ending
  in `!$omp end do` (GPU BR1 `:188`, BR2 `:225/234`, IP `:280/300`; legacy BR1 `:236,335,472`). No explicit
  barrier is needed there.
- Rotate back → surface integrals: implicit barrier at the end of the rotate-back `do`.
- Each element touches only faces where it is side 2, and each MPI face is touched once, so there are no
  write conflicts.
- Pre-existing, not from this PR: GPU `HexMesh_ComputeLocalGradientNS` ends `nowait` (`HexMesh.f90:5752`), and
  BR2/IP then prolong element gradients without a barrier. That is a possible race between local-gradient
  computation and prolongation under OpenMP.
