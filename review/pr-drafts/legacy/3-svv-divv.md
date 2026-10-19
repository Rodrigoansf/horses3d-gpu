## Fix the velocity divergence in SVV with energy gradient variables

`SVV_physical_dissipation_ENERGY` computed `divV = Hx(IX) + Hy(IY) + Hz(IZ)`, which for energy gradient variables is drho/dx + du/dy + dv/dz; it now uses the velocity components.

This changes the residuals of `TaylorGreenSVVLES` by up to 1.6%, so its five residual references are updated.
