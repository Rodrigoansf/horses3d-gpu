# Handoff: stack-PR review (#113–#117), continued locally

Read this first, then `review/STATUS.md` (section 0) and `review/pr-drafts/`.

## Who and what

The user is Rodrigoansf, a maintainer of horses-framework/horses3d-gpu, a high-order DG CFD solver ported to GPU with OpenACC/nvfortran. Its priorities are compressible Navier–Stokes and multiphase; NSSA, iNS and CAA are not. Legacy is horses-framework/horses3d, a separate repo; some bugs exist in both.

The job: review the zalbanob stack PRs (horses-framework/horses3d-gpu#113 to #117) and turn the useful parts into small, isolated, discussable PRs. Duplicates of Miguel's gradvars work, of the user's GMM_develop shock-capturing work, or of develop are dropped, and so are regressions.

## Rules (from the user)

- **Never push to horses-framework.** Work only in the forks, Rodrigoansf/horses3d-gpu and Rodrigoansf/horses3d.
- **Run PRs by the user before making them.** Keep each PR small and readable: one branch for minor fixes (fixes that don't change results), and one branch per change that does change results.
- **Check with the user before going out of scope.** Don't start a new line of work, or fix something you just noticed, without asking: it may be someone else's work. Note it and ask.
- **Commits are the user's:** author `Rodrigoansf <rodrigoansf@gmail.com>`, with no `Co-Authored-By: Claude` line. PR bodies carry no "Generated with Claude Code" footer.
- Write PR descriptions slowly and plainly, explaining the code for researchers who haven't seen it.
- Avoid performance regressions, especially extra host↔device transfers.
- Multi-GPU tests are run by hand on the cluster.
- Branch roles: `main` is heavily guarded, `develop` holds tested features, and other branches are work in progress.

## Setup in an empty folder

```
git clone https://github.com/Rodrigoansf/horses3d-gpu
git clone https://github.com/Rodrigoansf/horses3d
git -C horses3d-gpu remote add upstream https://github.com/horses-framework/horses3d-gpu
git -C horses3d     remote add upstream https://github.com/horses-framework/horses3d
git -C horses3d-gpu fetch --all && git -C horses3d fetch --all
git -C horses3d-gpu checkout claude/eager-lamport-ymhyjk   # review docs live here
```

## First task: put the user's name on the commits

The cloud session could not do this; its permission system blocked history rewrites. Copy the script out of the repo first, because it rewrites the branch it lives on:

```
cp horses3d-gpu/review/tools/tie-commits-to-rodrigoansf.sh /tmp/ && bash /tmp/tie-commits-to-rodrigoansf.sh horses3d-gpu horses3d
```

It rewrites 13 branches plus this review branch, checks that every tree is unchanged, and force-pushes with lease. The 12 open draft PRs follow their branches automatically. Afterwards, check with `git log --format='%an | %cn | %s' origin/develop..origin/fix/minor-develop` and make sure no `Co-Authored-By` line remains.

## Where things stand (15 Oct 2026)

Draft PRs are open **inside the forks only**, so the user can look at the diffs:

| Fork PR | Branch → base | Kind |
|---|---|---|
| Rodrigoansf/horses3d#1 | `legacy/minor-fixes` → `upstream-master` | TE sensor MPI + OpenMP crash fixes |
| Rodrigoansf/horses3d#2 | `legacy/te-sensor-source-term` → `upstream-master` | changes results |
| Rodrigoansf/horses3d#3 | `legacy/svv-energy-divv` → `upstream-master` | changes results + TaylorGreenSVVLES refs |
| Rodrigoansf/horses3d#4 | `legacy/limiter-pressure-reference` → `upstream-master` | changes results; to discuss |
| Rodrigoansf/horses3d#5 | `legacy/aliasing-sensor-realloc` → `upstream-master` | crash fix |
| Rodrigoansf/horses3d-gpu#1 | `fix/minor-develop` → `develop` | 9 minor fixes |
| Rodrigoansf/horses3d-gpu#2 | `fix/minor-GMM` → `GMM_develop` | 5 minor fixes (incl. `make mu` build) |
| Rodrigoansf/horses3d-gpu#3 | `change/strong-form-split-fluxes` → `develop` | sharp fluxes (strong form + aliasing sensor) |
| Rodrigoansf/horses3d-gpu#4 | `change/svv-energy-divv` → `GMM_develop` | same as legacy #3 |
| Rodrigoansf/horses3d-gpu#5 | `change/te-sensor-source-term` → `GMM_develop` | same as legacy #2; needs `fix/minor-GMM` to run |
| Rodrigoansf/horses3d-gpu#6 | `change/limiter-pressure-reference` → `develop` | same as legacy #4 |
| Rodrigoansf/horses3d-gpu#7 | `fix/aliasing-sensor-realloc` → `develop` | same as legacy #5 |

`upstream-master` in the legacy fork is upstream master `e23a7a2`. The fork's own `master` has the user's three MMS commits and is behind upstream: **leave it alone**. The GPU fork's `develop` and `GMM_develop` equal upstream's `1a173a52` and `630879e6`.

The user is discussing these at the next team meeting; nothing goes to horses-framework until they decide.

## Open items (ask the user before starting any of them)

- **GPU runs of the new commits (laptop RTX 3060, cc86).** Not yet run on a GPU: the device-data commits in `fix/minor-develop` (balance enter/exit, `sem` teardown; add a leak check), the `make mu` fix in `fix/minor-GMM` (then `Multiphase/EntropyConservingTest` on GMM), and `LimiterTest` on `change/limiter-pressure-reference`.
- **Superseded branches to delete** (the cloud proxy blocked deletion): `stack-pick/*`, `fix/gpu-port-develop`, `fix/gpu-port-GMM`, `discuss/legacy-shared-bugs`, `review/gpu-results` in the GPU fork; `legacy/te-sensor-padapt-mpi`, `legacy/sc-sensor-omp-shared` in the legacy fork. Do **not** touch the `miguel_*`, `arr/*` and `feature/*` branches: they are mirrored from upstream and are other people's work.
- **Known, not being fixed here:**
  - `TaylorGreenSVVLES` on GPU doesn't match the CPU: the SVV branch of `TimeDerivative_ComputeArtificialViscosity` runs on the host without refreshing `Q`/gradients and doesn't push the flux back.
  - Anisotropic orders crash on GPU in `HexMesh_ProlongSolToFaces`.
  - `Face_AdaptSolToFace` lost legacy's p-nonconforming interpolation.
  - GPU volume monitors are stale.
  - `TruncationErrorClass` has `private(S)` with `S` zeroed outside the OpenMP loop.
  - TaylorGreenSVVLES's kinetic-energy asserts have tolerances larger than the values they check.

## Build and test notes

- **Builds:** run `cd Solver && ./configure && make ns mu COMPILER=gfortran MODE=RELEASE COMM=SEQUENTIAL ENABLE_THREADS=NO`. Don't use `-j`: the Makefile isn't parallel-safe (module order).
- **GPU builds:** use `COMPILER=nvfortran COMM=SERIAL` with a local cc86 edit to the `-gpu=` flags in `Makefile.in`; don't commit that edit. nvfortran forces `ENABLE_THREADS=NO`. A full disk during the device link can produce a truncated binary while `make` still reports success; check free space or set `TMPDIR`.
- **Test problem files:** build them with `make ns` (or `make mu`) in each test's `SETUP`, not plain `make`, which also tries the NSSA/iNS libraries.
- **`./configure`** rewrites two `Solver/test/Acoustic/*/horses3d.caa` symlinks in the legacy repo. Never commit them; restore with `git checkout -- Solver/test/Acoustic`.
- **MPI** without METIS needs `partitioning = SFC`.
- **Scratch cases** used as PR evidence are in `review/scratch-cases/`.
