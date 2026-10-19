## Positivity limiter: use the pressure of the average state

This changes the reference pressure of the positivity limiter to be the pressure of the cell-average state rather than the average of the nodal pressures, as in Zhang & Shu (2010) (cherry-picked from #115). Pressure is concave in the conservative variables, so the old reference was smaller and the limiter pulled the solution towards the average more than needed. It also skipped elements whose nodal pressures were all equal and below the minimum.

The `LimiterTest` reference values are updated. CPU and GPU give the same numbers, and legacy gives the same with the same change (horses-framework/horses3d#384).
