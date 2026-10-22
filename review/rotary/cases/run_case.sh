#!/bin/bash
# run_case.sh <tag> <nranks> <control file> [case dir]: run horses3d.ns in the case dir (default: the PR's
# RotaryPeriodic test), keep log + RESULTS in design/review-rotary/runs/<tag>/. Run through tools/heavy.sh.
source /opt/intel/oneapi/mpi/2021.17/env/vars.sh > /dev/null 2>&1
export I_MPI_FABRICS=shm OMP_NUM_THREADS=1
tag=$1; n=$2; ctl=$3
T=${4:-/home/rodrigo/Desktop/Horses3d-Epicure/gpu-wt/rev145/Solver/test/NavierStokes/RotaryPeriodic}
OUT=/home/rodrigo/Desktop/Horses3d-Epicure/gpu-wt/design/review-rotary/runs/$tag
rm -rf $OUT; mkdir -p $OUT
cd $T || exit 1
rm -rf RESULTS; mkdir RESULTS
cp $ctl $OUT/
/usr/bin/time -v mpiexec -n $n ./horses3d.ns $(basename $ctl) > $OUT/run.log 2>&1
rc=$?; echo "exit=$rc" >> $OUT/run.log
cp RESULTS/*.residuals RESULTS/*.probe RESULTS/*.surface $OUT/ 2>/dev/null
exit $rc
