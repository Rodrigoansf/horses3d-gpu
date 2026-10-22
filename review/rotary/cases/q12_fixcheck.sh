#!/bin/bash
# Check the axis-sign diagnosis: local one-line patch in SectorAngle (angle measured about the signed
# axis), rebuild, rerun the flipped-axis cases, then revert and rebuild the PR as it is. Never committed.
set -u
G=/home/rodrigo/Desktop/Horses3d-Epicure/gpu-wt; W=$G/rev145; D=$G/design/review-rotary; C=$D/cases
F="COMPILER=gfortran MODE=RELEASE COMM=PARALLEL ENABLE_THREADS=NO WITH_METIS=NO WITH_HDF5=NO WITH_MKL=NO"
R="systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 $G/tools/heavy.sh"
source /opt/intel/oneapi/mpi/2021.17/env/vars.sh > /dev/null 2>&1
P=$W/Solver/src/libs/rotation/RotationData.f90
python3 - "$P" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="      SectorAngle = SectorAngle - 2.0_RP * PI * anint(SectorAngle / (2.0_RP * PI))\n"
new=old+"      SectorAngle = sign(1.0_RP, rotationParams % axis(RotationAxisIndex())) * SectorAngle   ! REVIEW CHECK ONLY\n"
assert s.count(old)==1; open(p,'w').write(s.replace(old,new))
PY
git -C $W diff --stat
$R bash -c "cd $W/Solver && make ns $F > $D/runs/fixcheck-build.log 2>&1; echo exit=\$? >> $D/runs/fixcheck-build.log"
tail -1 $D/runs/fixcheck-build.log; ls -la --time-style=+%T $W/Solver/bin/horses3d.ns
T=$W/Solver/test/NavierStokes/RotaryPeriodic
for c in "fix-sector-plus 4 $C/sector-br1.control $C" "fix-sector-flip 4 $C/sector-br1-flip.control $C" "fix-rp-flip 8 $T/rp_sfc_flip.control $T" "fix-rp-plus 8 $T/rp_sfc.control $T"; do
  set -- $c; timeout 1500 $R $D/run_case.sh $1 $2 $3 $4; echo "== $1 rc=$?"
  grep -E "Sector angle|Rotation axis|failures out|Passed|Failed" $D/runs/$1/run.log | sort | uniq -c
done
python3 $C/compare.py v-annulus-br1 fix-sector-plus fix-sector-flip | grep -E "###|residual"
# revert and rebuild the PR as it is
git -C $W checkout -- Solver/src/libs/rotation/RotationData.f90
git -C $W status --short | grep -v '^??' ; echo "tracked changes above (should be none)"
$R bash -c "cd $W/Solver && make ns $F > $D/runs/fixcheck-revert.log 2>&1; echo exit=\$? >> $D/runs/fixcheck-revert.log"
tail -1 $D/runs/fixcheck-revert.log; ls -la --time-style=+%T $W/Solver/bin/horses3d.ns
