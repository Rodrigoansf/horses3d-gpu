## Compute the split-form sharp fluxes again (strong-form volume term and aliasing sensor)

In the GPU port the call that computes the split-form "sharp" fluxes was commented out in two places, so they used uninitialised arrays:

* `TimeDerivative_StrongVolumetricContribution`, used by the isolated time derivative of the truncation-error estimators (cherry-picked from #116).
* `Sensor_aliasing`, the aliasing shock sensor.

Both now call `SplitDG_ComputeSplitFormFluxes`, as legacy does. This changes results in those two paths only; no test uses them.
