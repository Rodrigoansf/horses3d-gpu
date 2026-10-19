## Fix GPU crash in ParamfileRegions (Cylinder test)

Since #119 the `Cylinder` test crashes on the GPU before the first time step. #119 added a surface monitor without a `reference surface`, and when a key is missing, `readRealValueInRegion` (and the integer and logical versions) allocates the value, fails to read it and deallocates it again. nvfortran 26.3 segfaults when an allocatable scalar component is deallocated through an allocatable dummy argument.

* The value is now read into a local variable, and `var` is only allocated when the key is present. The result is the same as before in every case.

Tested on the GPU: `Cylinder` runs again (10/10), and the other GPU CI cases are unchanged.
