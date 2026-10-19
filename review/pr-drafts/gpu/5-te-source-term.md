## Fix the source term in the truncation-error sensor

`Sensor_truncation` calls the user source term once per node, but it passed the coordinates of node (0,0,0) to every node and never initialised `S` (cherry-picked from #116). It now passes `x(:,i,j,k)` and sets `S = 0` before each call.

This changes the sensor whenever the source term is not zero. No test uses the truncation-error sensor, which only runs at all with horses-framework/horses3d-gpu#141. Legacy has the same bug (fixed in horses-framework/horses3d#382).
