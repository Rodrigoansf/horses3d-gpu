## ParamfileRegions: don't allocate a value only to deallocate it (fixes the GPU `Cylinder` crash)

### What happens

Since horses-framework/horses3d-gpu#119 (gauge-pressure monitors), `NavierStokes/Cylinder`, the first case of the GPU CI, crashes on the GPU before the first time step:

```
Thread 1 "horses3d.ns" received signal SIGSEGV, Segmentation fault.
#0  paramfileregions::readrealvalueinregion () at ParamfileRegions.f90:162
#1  surfacemonitorclass::surfacemonitor_initialization () at SurfaceMonitor.f90:104
#2  monitorsclass::monitors_construct () at Monitors.f90:160
```

horses-framework/horses3d-gpu#119 itself is fine. It added a third surface monitor to `Cylinder.control` (`p2-avg`, `pressure-average` with `Gauge pressure = .true.`), and that is the first monitor in the case without a `Reference surface` line. Reading a missing key goes down a path that nvfortran gets wrong.

### Why

`readRealValueInRegion` (and its integer and logical twins) does:

```fortran
if( .not. allocated(var)) allocate(var)
read(auxstr,*,iostat=io) var
if (io .lt. 0) then
   deallocate(var)            ! key missing: undo the allocation
end if
```

Here `var` is `self % referenceSurface`, an allocatable scalar component of the monitor. With nvfortran 26.3, **deallocating an allocatable scalar component through an allocatable dummy argument segfaults**, at any optimisation level. This 15-line program reproduces it (gfortran runs it fine):

```fortran
module m
   type t
      real(8), allocatable :: r
   end type
contains
   subroutine step(v)
      real(8), allocatable :: v
      if (.not. allocated(v)) allocate(v)
      deallocate(v)                 ! segfaults with nvfortran 26.3
   end subroutine
end module
program p
   use m
   type(t) :: x
   call step(x % r)
end program
```

Allocating through the dummy works, and so does deallocating the component in the scope that owns it. Only the deallocate through the dummy crashes.

### The fix

Read into a local, and allocate `var` only when there is something to put in it:

```fortran
read(auxstr,*,iostat=io) val
if (io .lt. 0) then
   if (allocated(var)) deallocate(var)
else
   if (.not. allocated(var)) allocate(var)
   var = val
end if
```

The end state is the same as before: allocated with the value when the key is present, not allocated when it is missing, deallocated when it was allocated on entry and the key is missing. Only the allocate-then-deallocate round trip is gone. One difference in an error case: when the key is present but its value doesn't parse, both versions leave `var` allocated with an undefined value, but the new one also overwrites a value that was already there. Same change in the three readers (integer, real, logical); the character reader doesn't allocate.

This doesn't change any result, so it could also go with the minor fixes; it is separate because it is a new finding, not part of the stack review.

### How it was checked

- The reproducer above segfaults; the fixed pattern runs with nvfortran 26.3 at `-O0` and at the release flags, with a missing and a present key, for real and logical components.
- GPU (RTX 3060 laptop), `NavierStokes/Cylinder` with the unmodified control file: on `develop` it segfaults before the first step; with this branch it runs and passes 10/10, bitwise identical to `develop` run with a `Reference surface` line added to monitor 3 (which `pressure-average` doesn't use). The other 17 cases (GPU CI list plus `TaylorGreenSVVLES`) are bitwise identical to `develop`.
- gfortran builds never had the crash, and the readers return the same values as before. Not run separately on the CPU; the same commit is in `GMM_develop`, whose CPU build was checked (`TaylorGreenSVVLES`, TE cases).

Legacy horses3d has the same reader, but it is built with gfortran/ifort, which don't have this bug, so no legacy PR.
