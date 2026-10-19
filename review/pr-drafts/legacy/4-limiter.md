## Positivity limiter: use the pressure of the average state

This changes the reference pressure of the positivity limiter to be the pressure of the cell-average state rather than the volume average of the nodal pressures, as in Zhang & Shu (2010). The old reference was smaller (pressure is concave), so the limiter limited more than needed.

`ForwardFacingStep_SSPRK33`, the only test that uses the limiter, does not change.
