# Draft review for horses-framework/horses3d-gpu #145 (and #387) — NOT POSTED

Proposed state: **Request changes** (silent wrong results in several configurations). Line numbers are
PR-head lines of #145 (da89463d). Comments marked [legacy] go on #387 only.

---

## Review body

Thanks Abbas. The approach (rotate side 2 into side 1's frame, rotate the flux back) looks right. I checked
it against the full 360° annulus (the same mesh revolved three times) with a perturbation sitting on the
periodic faces: the sector matches to round-off with BR1 and IP, serial and MPI, also with rotary faces
split across ranks.

A few cases give wrong results without an error, so I'd fix those first:

* `rotation axis = [-1,0,0]` (same geometry as the test) diverges: the angle is measured about +x but the
  rotation uses the signed axis.
* With `read partitioning from files = .true.` the angle stays 0 when no rank owns both sides of a rotary
  pair (log: `Sector angle (deg): 0.000`).
* BR2: the face gradients of side 2 are rotated before the BR2 face integrals add `η·unStar`, which by
  then is back in side 2's frame. On legacy the sector differs from the full annulus by a few percent with
  BR2 (BR1 and IP are fine).
* The angle comes from the first matched node only.
* `horses3d.nssa` passes the NS-only check but its SpatialDiscretization has no rotation hooks.

The rest are smaller: axis input checks, a test that loads the periodic faces more, the Cylinder.control
change (belongs to #139), and a question about defining the rotation per periodic pair. The same comments
apply to horses3d #387.

---

## Inline comments

**1. `Solver/src/libs/rotation/RotationData.f90:140`** (SectorAngle)
> This measures the angle about +x/+y/+z, but `BuildRotationMatrix` uses the signed axis, so
> `rotation axis = [-1,0,0]` rotates the wrong way (the RotaryPeriodic test goes to NaN with it).
> Multiplying the result by the sign of `axis(coord)` fixes it: with that line the [-1,0,0] case gets +120°,
> passes the test and matches the [1,0,0] result.

**2. `Solver/src/libs/discretization/DGSEMClass.f90:302`** (SyncPeriodicAngle)
> This is skipped with `read partitioning from files = .true.`. If no rank matches a rotary pair locally
> (all rotary faces are MPI faces, e.g. a sector partitioned in θ), the angle stays 0 on every rank and the
> run is wrong without an error. Could the angle be written to the .partitioning file next to the flag?

**3. `Solver/src/libs/mesh/HexMesh.f90:692`** (angle from the first matched node)
> If this node is on the axis (r = 0), atan2 gives 0 and nothing gets rotated. And with more than one
> Periodic pair, the master of the second pair can be on the other side (the zone order comes from the
> dictionary keys), which needs −angle. Could the angle be computed per pair from a node with r > 0, and
> checked to be the same for every matched face?

**3b. `Solver/src/libs/discretization/EllipticBR2.f90:193`**
> The side-2 gradients are rotated here, but `BR2_ComputeGradientFaceIntegrals` then adds `-η·unStar`
> to `storage(2) % U_x`, and by then `unStar(2)` has been rotated back to side 2's frame. With BR2 the
> sector doesn't match the full annulus (legacy, a few percent; BR1 and IP match to 1e-11). Rotating the
> side-2 gradients after the face integrals should fix it.

**3c. `Solver/src/libs/discretization/DGSEMClass.f90:247`**
> `horses3d.nssa` is built with `-DNAVIERSTOKES -DSPALARTALMARAS`, so it passes this check, but
> NavierStokesSolverRANS/SpatialDiscretization.f90 has no rotation hooks (only the shared BR1/BR2/IP ones
> fire). Either add them or stop for SPALARTALMARAS too.

**3d. `Solver/src/libs/mesh/RotaryFaceRotations.f90:164`** (and 191)
> Side-2 `unStar`/`FStar` are sized with that side's `Nel`, not `Nf`, so with different polynomial orders
> on the two sides (or Nx ≠ Ny and a rotated face) this loop doesn't cover the right points.

**4. `Solver/src/libs/rotation/RotationData.f90:119`**
> If the axis isn't x, y or z this turns rotary matching off without saying so, and the user then gets
> "was not able to find a partner". An error here would help. A zero axis gives NaN (`norm2` = 0).

**5. `Solver/src/libs/rotation/RotationData.f90:207`**
> This compares squared radii with the default 2·eps relative tolerance; rotated nodes are rarely exact
> copies the way translated ones are. The relaxed version (l. 249) compares r² with a length. Comparing r
> with a tolerance based on the element size would be more robust.

**6. `Solver/test/NavierStokes/RotaryPeriodic/RotaryPeriodic.control:26`** (design question)
> Since `periodic enabled` makes every Periodic pair rotary, translational and rotational periodicity can't
> be combined (e.g. an annular sector that is also periodic axially), and there is one angle per case.
> Would it make sense to give `rotation axis`/`rotation center` in the boundary block of the pair instead
> (like OpenFOAM's cyclic patches)? That would also allow any axis direction. The name `periodic enabled`
> also reads like it switches periodic BCs on in general.

**7. `Solver/src/libs/physics/common/FluidData.f90:16`**
> HexMesh gets the rotation symbols through this. A direct `use RotationData, only: ...` in HexMesh would
> keep RotationData out of every module that uses FluidData.

**8. `Solver/src/libs/mesh/RotaryFaceRotations.f90:43`**
> These loops go over all elements (and the rotate-back ones over all interior faces) to touch a few
> faces, six times per stage. On the GPU (sector case, NV_ACC_TIME) the four rotation kernels take ~2.7%
> of the time step. nvfortran also reports `Generating implicit copy(vrot(:))` for the kernels that call
> `RotateVectorAroundAxis`, so every launch copies the array result to/from the host. A list of rotary
> face IDs built once and R(±angle) stored once (applied with scalars) would remove both.

**9. `Solver/src/libs/mesh/RotaryFaceRotations.f90:214`**
> `merge(2, 1, f % elementIDs(2) == HMESH_NONE)` would say what this means without relying on the IDs'
> order.

**10. `Solver/test/NavierStokes/Cylinder/Cylinder.control:58`**
> This is the workaround for the nvfortran ParamfileRegions crash, which #139 fixes. It can go from this PR.

**11. `Solver/test/NavierStokes/RotaryPeriodic/SETUP/ProblemFile.f90:264`**
> The swirl is centred at 90° with σ = 5°, so the velocity at the periodic faces (0° and 120°) is ~1e-8 and
> a wrong state or gradient rotation wouldn't change the asserts. Centring it on a periodic face would
> test the coupling. I have a sector vs full-annulus case that agrees to 1e-11 if you want to use it.

**12. `Solver/test/NavierStokes/RotaryPeriodic/RotaryPeriodic.control:58`**
> `cyl-drag`/`cyl-lift` on the inflow wall look copied from Cylinder (cl = -2000.88). Probes next to both
> periodic faces would say more.

**13. `.github/workflows/CI_parallel_NS.yml:1383`**
> Only the 8-rank run. A serial run would cover the non-MPI path.

**14. [legacy] `Solver/test/NavierStokes/RotaryPeriodic/SETUP/ProblemFile.f90`** (probe_u assert)
> `probe_u = 4.04e-9` with tol 1e-11 on value+1 checks almost nothing.

**15. [legacy] `Solver/src/NavierStokesSolver/SpatialDiscretization.f90`** (no diff line; put in the body)
> With shock capturing, the artificial-viscosity face flux averages `storage(2) % AviscFlux` without the
> rotation (l. 1763 and 1855).

**16. [legacy] `Solver/src/libs/timeintegrator/AnalyticalJacobian.f90`** (no diff line; put in the body)
> The analytical Jacobian reads the rotated side-2 state without the rotation. Either support it or stop
> with an error when rotary periodic BCs are used with it.

---

## Not for the PR (notes for Rodrigo)

* Legacy CI failure (MixedRK) is flaky: same source passed on the first push.
* GPU develop issues seen while testing (with periodic BCs off): BR2 debug prints every stage; Euler
  segfaults with 4 ranks (legacy fine); Entropy/Energy gradient variables give bitwise the same result as
  State.
* The PR is the periodic half of Abbas's `dumbSRF` branch (keywords `srf enabled` / `periodic enabled`
  there); the shared RotationData and the FluidData re-export make sense in that context — worth asking
  how the SRF part will follow before settling the keyword names.
