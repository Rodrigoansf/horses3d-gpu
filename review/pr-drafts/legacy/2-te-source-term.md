## Fix the source term in the truncation-error sensor

`Sensor_truncation` passed the coordinates of node (0,0,0) to every node and never initialised `S`. It now passes `x(:,i,j,k)` and sets `S = 0` before each call.

Built with `-finit-real=inf`, a uniform-flow case flagged every element before and none after. No test uses the truncation-error sensor.
