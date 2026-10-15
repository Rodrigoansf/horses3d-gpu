## GMM_develop: minor fixes from the review of the stack PRs

This PR collects the small fixes for `GMM_develop`. None of them changes results in a case that runs today. They fix a broken build, memory problems and crashes. Three changes that *do* change results have their own PRs: "SVV divV", "TE sensor source term" and "split form: compute the sharp fluxes again" (on develop; GMM_develop gets it by merging develop).

Each commit stands on its own and explains itself in its message, so commit by commit is the easiest way to review. Here is the slow version.

Nothing here adds host↔device transfers to the time loop.

---

### 1. `make mu` builds again (1 commit)

`GMM_develop` changed `HexMesh_ComputeLocalGradientNS` so that it converts `Q` to the selected gradient variables (`NSGradientVariables_selector`, `Q_grad_NS`) before differentiating. Those two only exist in the Navier–Stokes build, so `make mu` (and NSSA) stopped compiling on this branch, with both nvfortran and gfortran. The laptop GPU run hit this, and it's why `Multiphase/EntropyConservingTest` couldn't run there.

The fix uses the new path only for Navier–Stokes without Spalart–Allmaras. Everything else differentiates `Q` directly, as `develop` does:

```fortran
#if defined(NAVIERSTOKES) && (!defined(SPALARTALMARAS))
      ... element loop: convert to gradient variables, then differentiate (unchanged)
#else
      ... same element loop, but:
         call HexElement_ComputeLocalGradient(self % elements(eID), NCONS, NGRAD, self % elements(eID) % storage % Q)
#endif
```

The `use VariableConversion, only: NSGradientVariables_selector` line gets the same guard.

The Navier–Stokes path is untouched. This one is worth a look from Miguel, since it touches his gradient-variables work.

### 2. Same two fixes as on develop (2 commits)

These are identical to the corresponding commits in the develop minor-fixes PR, so the explanation is short:

- **`Face_Assign` aliased instead of copying**. `copy = original` left both faces pointing to the same geometry and storage. The truncation-error sensor copies the mesh this way (`coarseSem = sem`) and then lowers the coarse mesh's order, which reallocated face data the fine mesh was still using.
- **Map every NodalStorage order to the device**. The device copy only went up to the x-order of element 1. Higher orders were never mapped.

### 3. Truncation-error sensor: MPI and OpenMP (2 commits)

These two are the same as the "minor fixes" PR for legacy horses3d, which has the same bugs. There's a fuller explanation there.

- **MPI: build the coarse mesh with `pAdapt_MPI`**. The sensor lowers the order of its coarse mesh with `HexMesh_pAdapt`, whose own comment says *"this one does not work with MPI"*. In MPI runs it now uses `pAdapt_MPI`, as the RL p-adaptation does. Serial runs are unchanged.
- **OpenMP: complete two `shared(...)` lists**. Two loops in `SCsensorClass.f90` use `default(private)` but don't list everything they read: `sensor`, `t`, `NodalStorage`, `thermodynamics`, `dimensionless` and `refValues`. Each thread then gets uninitialised copies. This only matters with `ENABLE_THREADS=YES`, which nvfortran builds don't use.

---

### How it was checked

**CPU (gfortran 13), this branch:**
- `make ns mu` builds (serial). Before this PR, `make mu` did not build.
- `NavierStokes/Cylinder` 9/9, `TaylorGreenSVVLES` 8/8 (as on `GMM_develop`), `Multiphase/EntropyConservingTest` 5/5.
- A small truncation-error case (TaylorGreenSVVLES setup, `Shock sensor = truncation error`, 3 steps) runs to the end. Without the Face_Assign fix it segfaults at the first time step. In practice, the TE sensor can't be used on this code without this PR.
- The two sensor commits were not run with threads or MPI on this code; that was done in legacy (below).

**Legacy horses3d** (same two sensor fixes): with a 2-rank MPI run and a 4-thread run of a small truncation-error case, master segfaults and the fixed branch runs to the end. The 4-thread residuals are bit-identical to the serial ones.

**GPU (RTX 3060 laptop).** The Face_Assign and NodalStorage commits ran earlier on `GMM_develop`, together with the strong-form change. All 19 single-GPU CI cases gave output bitwise identical to `GMM_develop`. The `make mu` fix was written after that run and has not been run on a GPU yet. It leaves the Navier–Stokes code identical after preprocessing. The two sensor commits don't affect the GPU build: OpenMP is off there, and no single-GPU case uses MPI.

**Not checked:** multi-GPU. A GMM case with MPI and the truncation-error sensor would need to be run on the cluster; there is no such case yet.
