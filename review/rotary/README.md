# Review of the rotary periodic PRs (horses3d-gpu #145, horses3d #387)

Working notes for Rodrigo's review of AbbBallout's PRs. Nothing here has been posted to GitHub.
This branch starts at the PR head (da89463d) so fixes can be prototyped on top of it.

- `HANDOFF.md`: what to do next and the rules (start here in a new session).
- `REVIEW.md`: full report (what was run, findings, performance, design).
- `github-review-draft.md`: draft review body and inline comments, waiting for Rodrigo's go.
- `E-verify.md`: independent code-reading check of the findings.
- `BRIEF.md`: context given to the review agents.
- `cases/`: validation harness. `make_cases.py` writes a 120° sector (rotary periodic) and the same mesh
  revolved three times (full annulus, no periodic BCs), a problem file with a 120°-periodic swirl
  centred on the periodic faces, and control files (BR1, BR2, IP, Entropy, Energy, Euler, flipped axis).
  `compare.py A B` compares the 32 probes and the residuals of two runs (correct = ~1e-11).
  `reorder_theta.py` renumbers the sector by angle so SFC partitioning puts rotary faces on different
  ranks; `split_pairs.py` splits the periodic surfaces in two pairs. `run_case.sh` and `q12_fixcheck.sh`
  are the laptop scripts (Intel MPI path, heavy-job lock); adapt paths before using them elsewhere.
  Meshes: `gmsh -3 MESH/sector.geo -o MESH/sector.msh` (same for annulus). Without METIS the controls
  use `partitioning = SFC`.
