## Fix the actuator line: serial runs, threaded build and the multiphase source monitor

Three fixes for the actuator-line cases, cherry-picked from #113 and #117:

* `newPointToFind` was zeroed in serial runs, where it is not allocated.
* The `!$omp do` of the point search was closed ~80 lines after its loop and listed variables that no longer exist, so `ENABLE_THREADS=YES` did not compile.
* The multiphase `source` volume monitor was lost in the GPU port, so the multiphase `ActuatorLineInterpolation` control file was rejected at start-up.

The NS case is unchanged. The multiphase case now runs but fails 5 of its 10 checks: its reference values come from legacy, and this code differs by up to 1.4e-7 (CPU and GPU agree to 2e-12). Should we update the reference values, or first find where the multiphase solver differs from legacy?
