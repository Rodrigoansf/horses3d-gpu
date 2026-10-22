# Review: rotary periodic BCs (AbbBallout) — horses3d-gpu #145, horses3d #387

Reviewer notes for Rodrigo. Nothing here has been posted. Draft GitHub comments: `github-review-draft.md`.

## Verdict

The method is the standard one: rotate the side-2 trace (state and gradients) into side 1's frame, compute
the usual face flux, and rotate the flux sent back to side 2. It is implemented correctly for the case it
was written for. A 120° sector with these BCs reproduces a full 360° annulus to round-off (≤ 3e-11 relative on
32 probes and the residuals) with BR1 and IP, serial and MPI, including rotary faces split across ranks.

It is not ready to merge as is. There are four silent wrong-result bugs reproduced by runs (axis sign,
read-partitioning, BR2, and the input checks), and three more found by reading (SA solver, legacy shock
capturing, mixed polynomial orders). The design (one
global switch, one global angle, axis x/y/z only) is narrower than it needs to be. The test would not catch
most mistakes in the state/gradient rotation.

## What was run (all local, nothing pushed)

GPU-repo PR head da89463d, gfortran RELEASE, MPI (Intel MPI), no OpenMP; SFC partitioning (no METIS here).
Validation case: the PR's sector mesh (80 rotary faces) vs the same mesh revolved 3× (full annulus, no periodic BCs),
with a swirl/radial/axial perturbation centred on the periodic faces, exactly 120°-periodic, fixed dt, 200 steps,
32 probes next to both periodic faces and inside. Scripts and logs: `cases/`, `runs/`.

| case | result |
|---|---|
| PR test (8, 4, 1 ranks) | passes; residuals bitwise identical across rank counts |
| sector vs annulus, BR1 (1, 4, 8 ranks) | ≤ 2.6e-11 relative — correct |
| sector vs annulus, IP | ≤ 2.5e-11 — correct |
| rotary faces split across ranks (θ-ordered mesh, 2/3/4 ranks) | ≤ 2.3e-11 — MPI path correct |
| BR2, dt = 3e-4, legacy (1 thread and 4 threads, bitwise equal) | **sector ≠ annulus: 4% of probe range, residuals 1.4–10× off**; annulus alone stable → finding 3e |
| BR2, dt = 3e-4, GPU repo | NaN on the plain annulus too (legacy stable) → BR2 broken on GPU develop, can't judge there |
| gradient variables Entropy, legacy | differs from State (8e-4) as expected — confirms the GPU repo ignores the keyword |
| Euler (`Flow equations = "Euler"`) | segfault on the annulus too → pre-existing, can't judge |
| gradient variables Entropy / Energy | bitwise equal to State on GPU develop (keyword has no effect) |
| `rotation axis = [-1,0,0]` (same geometry) | **NaN** (PR test fails 7/7; sector run diverges) |
| `read partitioning from files = .true.` (θ-ordered, 3 and 4 ranks) | **angle 0, wrong answer, no error** (residuals 17–54× off) |
| `rotation axis = [1,1,0]` | rotary matching silently off → "Face … was not able to find a partner" |
| `rotation axis = [0,0,0]` | NaN from step 0, no error |
| `periodic relative tolerance = .true.` | correct (≤ 2.6e-11) on this mesh |
| two rotary pairs (PR mesh with each side split at r = 6) | correct, but both pairs got the same master side; my attempts to force opposite masters hit mesh-reader limits → finding 3b stays code-reading |
| legacy #387 PR test (8 ranks; 1 rank × 4 threads) | passes 8/8 |
| legacy sector vs annulus, BR1: 1 thread, 4 threads, 2 ranks × 2 threads | ≤ 2.6e-11 — OpenMP and hybrid correct; legacy vs GPU-repo build ≤ 4.4e-13 |
| legacy sector vs annulus, Euler (1, 4 threads, 2×2) | ≤ 3.3e-11 — correct |
| nvfortran 26.3 build (cc86, serial), GPU run | builds; PR test passes on GPU; sector vs annulus on GPU ≤ 2.4e-11; GPU vs CPU ≤ 2.7e-12 |
| GPU cost (NV_ACC_TIME, sector, 200 steps) | 4 rotation kernels = 136 ms of ~5.0 s time-stepping GPU time (2.7%); each launch also does implicit host↔device copies |

## Findings

### Bugs (wrong results without an error)

1. **Axis sign** — `RotationData.f90:128-150` (`SectorAngle`) measures the angle counter-clockwise about
   the *positive* coordinate axis (fixed atan2 planes), but `BuildRotationMatrix` uses the *signed* user
   axis. `rotation axis = [-1,0,0]` describes the same geometry and diverges to NaN (PR test: 7/7 asserts
   fail; validation: NaN at step 17); both runs print the same angle (-120°), only the axis differs.
   Fix: multiply the angle by `sign(1, axis(coord))`. Checked with that one-line local patch (reverted):
   the -x run then gets +120°, passes the PR test 7/7 and matches the annulus to 2.6e-11, and +x is
   unchanged.
2. **Read-partitioning path** — `DGSEMClass.f90:262-305`: with `read partitioning from files`, root never
   builds the full mesh and `SyncPeriodicAngle` is not called; ranks get the angle only if they match a
   rotary pair locally. When every rotary face is an MPI face (normal for a sector cut in θ), the angle stays
   0 on all ranks: the log says `Sector angle (deg): 0.000` and the run finishes with wrong results.
   Fix: write the angle to the `.partitioning` file (the flag is already there), or take the angle /
   number of sectors from the control file and check it during matching.
3. **One global angle from the first matched node** — `HexMesh.f90:688-705`:
   (a) if that node is on the axis (r = 0, e.g. a pipe sector whose periodic faces meet at the centreline),
   `atan2(0,0) = 0` → angle 0 → no rotation, silently; (b) with several Periodic pairs, the master of each
   pair is the zone met first, and zone order is the hash order of the boundary names
   (`zoneNameDictionary % allKeys()`, ZoneClass.f90:67; the logs show `sideb` before `sidea` but `sidea_in`
   before `sideb_in`), so a pair whose master is on the other side needs −angle but gets +angle (not
   reproduced: see table); (c) no check that all matched pairs give the same angle. Fix: compute the
   angle per matched face (or per zone pair) from a node with r > tol, store it (or its sign) on the face,
   and stop with an error if pairs disagree.

3d. Each rank re-runs `ConstructPeriodicFaces` on its own partition after `SyncPeriodicAngle` and
   overwrites the broadcast angle with its local one (`periodicAngleSet` is local, `HexMesh.f90:527`), so the
   "root only" comments (`HexMesh.f90:752`, `RotationData.f90:156`) are wrong and a rank can end up with a
   different angle (or 0, see 3a) than root.
3e. **BR2 mixes frames** — `EllipticBR2.f90:193` rotates the side-2 face gradients before
   `BR2_ComputeGradientFaceIntegrals`, which then adds `-η·unStar` to `storage(side) % U_x`; for side 2,
   `U_x` is already in side 1's frame but `unStar` has been rotated back to side 2's frame. Reproduced on
   legacy (where BR2 runs): sector vs annulus differ by 4% of the probe range, residuals 1.4-10× off
   (dt = 3e-4; the annulus alone is fine; 1 and 4 threads give bitwise the same result). BR1 and IP are correct. Same code in the GPU repo (BR2 does
   not run there on develop). Fix: rotate the side-2 face gradients after the BR2 face integrals, or keep
   unStar(2) in side 1's frame for that update.
3f. **Spalart-Allmaras (`horses3d.nssa`)** is built with `-DNAVIERSTOKES -DSPALARTALMARAS`, so it passes
   the NS-only check (`DGSEMClass.f90:247`), but `NavierStokesSolverRANS/SpatialDiscretization.f90` has no
   rotation hooks while the shared BR1/BR2/IP hooks still rotate gradients → wrong without an error.
   Either add the hooks or also stop for SPALARTALMARAS. (code reading, both repos)
3g. **Legacy shock capturing**: the artificial-viscosity face flux averages `storage(2) % AviscFlux`
   unrotated (`NavierStokesSolver/SpatialDiscretization.f90:1763`, MPI `:1855`). (code reading; commented
   out in the GPU repo)
3h. The rotate-back loops run over `0:Nf` (`RotaryFaceRotations.f90:164,191`), but side-2 `FStar`/`unStar`
   are sized `0:Nel` of that side (`StorageClass.f90` face storage pointers). For p-non-conforming faces
   (mixed orders, p-adaptation) or Nx ≠ Ny with a rotated face, points are rotated twice, skipped, or
   written out of bounds. (code reading)

### Input checking

4. `periodic enabled = .true.` with a non-aligned axis silently disables rotary matching
   (`RotationData.f90:119`); the user gets "Face N in zone 1 was not able to find a partner". A zero axis
   gives NaN everywhere (`:111`). Both should stop with a clear message. The docs even describe the silent
   fallback.
5. Node matching compares squared radii: strict `AlmostEqual` (2·eps relative on r², `:207`) is fragile
   for rotated nodes, which are never bit-exact copies (a failure is loud: "no partner"); the relaxed
   variant (`:249`) compares r² (length²) against `1e-4·min_edge_length` (length). Compare r, with a
   tolerance tied to the element size.

### Design / alternatives

6. A single global switch makes *all* Periodic pairs rotary: translational and rotational periodicity
   cannot be combined (an annular sector that is also periodic axially is a standard LES set-up), and only
   one sector angle per case. Other codes put the transform on the pair (OpenFOAM `cyclic` with
   `transform rotational; rotationAxis; rotationCentre`, SU2 `MARKER_PERIODIC` with centre/angles/
   translation per pair). Here that would be `rotation axis` / `rotation center` inside the
   `#define boundary` block of the periodic pair, the angle computed per pair at matching and checked.
7. Axis limited to x/y/z for no real reason: the rotation matrix is already general; matching could use
   r = |(x−c) − ((x−c)·a)a| and the axial coordinate (x−c)·a, the angle an atan2 in the plane ⟂ a.
   That also removes finding 1.
8. `periodic enabled` reads as "enable periodic BCs". Something like `rotary periodic = .true.` (or the
   per-pair keywords above) is clearer. `rotation axis/center` are generic names that a future rotating
   frame (the control file says "no SRF") would also want — worth agreeing on now.
9. `FluidData` now re-exports `RotationData` (`FluidData.f90:16`), so every module that uses FluidData
   sees `rotationParams`, `SectorAngle`, `CompareTwoNodesRevol`…. HexMesh.f90 relies on it (it gets all its
   rotary symbols through `use FluidData`). A direct `use RotationData, only: …` in HexMesh would make the
   dependency explicit and the re-export unnecessary. Node-matching helpers would sit better in libs/mesh
   next to `CompareTwoNodes` than in a new `libs/rotation`.

### Maintainability

10. The state is rotated in place in face storage(2) and ~14 hook calls are spread over
    SpatialDiscretization, BR1/BR2/IP (+ MLRK in legacy). Every future face-flux path (e.g. the mortars in
    horses3d #348) has to remember them or give silently wrong results. At least document the invariant
    ("after prolongation, side 2 of a rotary face is in side 1's frame") next to the face storage; consider
    one routine called right after prolongation that does all rotations.
11. `ReceivedSide` (`RotaryFaceRotations.f90:209-214`) relies on `HMESH_NONE = 0` being smaller than any
    element ID; `merge(2, 1, f % elementIDs(2) == HMESH_NONE)` says what it means. Checked: MPI face sides
    match the serial face (`HexMesh_UpdateFacesWithPartition`), so the sign logic is right.
12. `.partitioning` file format changes (new block before `meshIsHOPR`): files from older builds can no
    longer be read with `read partitioning from files`. Fine, but say so.
13. Legacy: `AnalyticalJacobian.f90:202` prolongs Q without the rotation and the flux Jacobians never get
    the rotation factors, so implicit runs with the analytical Jacobian (reachable with NS + IP, or Euler)
    get an inconsistent coupling block for rotary faces: slower convergence as a preconditioner, possible
    accuracy loss in Rosenbrock stages. Error out or support it.

### Performance

14. Disabled (every existing case): each hook returns on a host-side check before any kernel/loop; the
    only costs are one logical per Face and two `mpi_allreduce` at start-up. Nothing measurable.
15. Enabled: per RK stage 6 extra kernels/loops; two run over all elements (grid 2400) and two over all
    interior faces (grid 6570) to touch 80 rotary faces; cos/sin recomputed per node; one extra OpenMP
    barrier. Measured on the GPU (NV_ACC_TIME, sector case): 136 ms out of ~5.0 s of time-stepping GPU
    time, 2.7%. nvfortran also reports `Generating implicit copy(vrot(:))` for three of the kernels
    (the array result of the inlined `RotateVectorAroundAxis`; the gradient kernel has three such
    temporaries): every launch does 1-3 copyin + copyout transfers (601-1803 per kernel in 200 steps).
    An array not privatised in a compute region is shared, so correctness relies on the compiler keeping
    it in registers (it does at -O3: GPU matches CPU to 2.7e-12). Scalar code or a precomputed R(±angle)
    removes both the copies and that reliance. A list of rotary face IDs built once would make the cost
    O(rotary faces), i.e. well under 1%.

### Tests / CI / hygiene

16. The test checks regression values only. The swirl is centred at 90° with σ = 5° and the periodic
    faces are at 0° and 120° (6σ away), so the velocity at the periodic faces is ~1e-8: a wrong state or
    gradient rotation would not change the asserts. It does catch a wrong flux rotation (the pressure term
    of the momentum flux must be rotated even at rest — the axis-sign run fails). Put the perturbation on the
    periodic faces and, better, compare against the full annulus (case available in `cases/`).
17. Monitors `cyl-drag`/`cyl-lift` on a slip wall named `inflow`, `cl = -2000.88` asserted to 1e-11:
    copy-paste leftovers; use probes next to both periodic faces. Legacy additionally asserts
    `probe_u = 4.04e-9` with tol 1e-11 on value+1, which checks almost nothing.
18. CI: GPU repo runs the case only in CI_parallel_NS (gfortran, 8 ranks, METIS). No serial run, no OpenMP,
    no GPU. Whether any rotary face is an MPI face with METIS is not known (with SFC on this mesh none is).
19. `Cylinder.control` (GPU PR) adds `Reference surface = 1.0` to monitor 3: that is the local workaround
    for the nvfortran 26.3 ParamfileRegions crash, fixed properly by horses3d-gpu #139. Drop it from this PR.
20. Legacy CI failure (`Multiphase:: MixedRK`, run 39777405739) is not from this PR: the same workflow
    passed on the PR's first push and the Fortran source is identical between the two pushes (only two CI
    yaml lines changed). Flaky.
21. One 1.6k-line commit; branch `abbas_developement` (typo); #387 description is only "same as #145gpu" —
    say what differs (MLRK hooks, element lists, no OpenACC).

## Is it necessary?

Neither master/develop has rotational periodicity or a rotating frame, and no issue asks for it. It is
part of ongoing work: this PR is the periodic half of Abbas's `dumbSRF` branch (horses3d-gpu, "initial SRF
implementation", 8 Oct), where `RotationData` serves both SRF and periodic revolution (`srf enabled` /
`periodic enabled`, shared `rotation axis/center`) — that is why the generic names, the separate
`libs/rotation` and the FluidData re-export exist. Oscar's `oscarFwhMrf`/`oscarFwhDumbMrf` branches build
FWH surfaces as 1/3 of a cylinder rotated twice (the same 120° sector), and the legacy mortars branch
(`347-merge-mortars-to-master`, PR #348) has sliding-mesh work that also handles periodic BCs.
Simulating one sector instead of 360° is a real saving (3× here, N× for N blades), so the feature is worth
having. The question for the team is the interface: settle it together with SRF (per-pair definition,
keyword names), and check how it will combine with the sliding mesh/mortars.

## Pre-existing problems seen while testing (not this PR)

- horses3d-gpu develop: BR2 diverges on the plain annulus at dt = 3e-4, where legacy BR2 is stable, and
  prints "I am in BR2 line …" every stage (debug prints left in);
  `Flow equations = "Euler"` segfaults with 4 ranks on the plain annulus (legacy runs it fine);
  `gradient variables = Entropy/Energy` give bitwise the same result as State.
- horses3d-gpu develop does not build with `ENABLE_THREADS=YES` (ActuatorLine.f90) — fixed by #143.
- horses3d-gpu develop: `ComputeLocalGradientNS` ends its loop with `nowait` (`HexMesh.f90:5752`) before
  BR2/IP prolong the gradients — possible OpenMP race (from the verifier, not checked further).
- Independent code-reading check of these findings: `E-verify.md`.
