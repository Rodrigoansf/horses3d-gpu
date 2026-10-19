## Fix the velocity divergence in SVV with energy gradient variables

`SVV_physical_dissipation_ENERGY` computed `divV = Hx(IX) + Hy(IY) + Hz(IZ)`, which for energy gradient variables (rho, u, v, w, T) is drho/dx + du/dy + dv/dz. It now uses the velocity components, as the rest of the routine does (cherry-picked from #116). Legacy has the same line (fixed in horses-framework/horses3d#383).

This changes the residuals of `TaylorGreenSVVLES` by up to 1.6%, so its reference values are updated (the same values as legacy with the fix). On `develop` it has no effect yet because shock capturing is not applied; it will once `GMM_develop` is merged.
