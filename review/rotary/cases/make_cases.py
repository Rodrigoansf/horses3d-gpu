#!/usr/bin/env python3
"""Validation cases for the rotary periodic PR (horses3d-gpu #145).

A 120 deg sector with rotary periodic BCs must give the same solution as the full 360 deg annulus
(no periodic BCs) when the initial condition is exactly 120 deg periodic. The swirl is centred on
the periodic faces (theta0 = 0) so the coupling is loaded by velocity, gradients and pressure.
Probes sit next to both periodic faces and inside the sector; the annulus uses the same points.
"""
import math, os, re, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
TEST = os.environ.get('RP_TEST', '/home/rodrigo/Desktop/Horses3d-Epicure/gpu-wt/rev145/Solver/test/NavierStokes/RotaryPeriodic')
BIN = os.environ.get('RP_BIN', '/home/rodrigo/Desktop/Horses3d-Epicure/gpu-wt/rev145/Solver/bin/horses3d.ns')

# ---------------------------------------------------------------- meshes (same layers as the PR test)
GEO_HEAD = """Mesh.MshFileVersion = 4.1;
N = 16; Nx = 5; Na = 30;
l1=1.0; l2=10.0; Lx=1.0; c1 = 1.0;
Point(1) = {0.0, 0.0, 0.0, c1};
Point(2) = {0.0, l1, 0.0, c1};
line[] = Extrude {0.0, l2, 0.0} { Point{2}; Layers{N}; };
surface[] = Extrude {Lx, 0.0, 0.0} { Line{line[1]}; Layers{Nx}; Recombine; };
"""
SECTOR = GEO_HEAD + """
Extrude {{1, 0, 0}, {0, 0, 0}, 2*Pi/3} { Surface{5}; Layers{Na}; Recombine; }
Physical Surface("inflow") = {14};
Physical Surface("outflow") = {22};
Physical Surface("top") = {18};
Physical Surface("bottom") = {26};
Physical Surface("sidea") = {5};
Physical Surface("sideb") = {27};
Physical Volume("fluid") = {1};
Mesh.ElementOrder = 3;
"""
# three successive 120 deg extrusions; the last top surface is merged with surface 5 by Coherence
ANNULUS = GEO_HEAD + """
e1[] = Extrude {{1, 0, 0}, {0, 0, 0}, 2*Pi/3} { Surface{5}; Layers{Na}; Recombine; };
e2[] = Extrude {{1, 0, 0}, {0, 0, 0}, 2*Pi/3} { Surface{e1[0]}; Layers{Na}; Recombine; };
e3[] = Extrude {{1, 0, 0}, {0, 0, 0}, 2*Pi/3} { Surface{e2[0]}; Layers{Na}; Recombine; };
Coherence;
Physical Surface("inflow")  = {e1[2], e2[2], e3[2]};
Physical Surface("top")     = {e1[3], e2[3], e3[3]};
Physical Surface("outflow") = {e1[4], e2[4], e3[4]};
Physical Surface("bottom")  = {e1[5], e2[5], e3[5]};
Physical Volume("fluid") = {e1[1], e2[1], e3[1]};
Mesh.ElementOrder = 3;
"""

# ---------------------------------------------------------------- problem file
IC = """            omega  = 0.1_RP   ! swirl rate
            theta0 = 0.0_RP   ! centred on the periodic faces
            sigma  = 15.0_RP * PI/180.0_RP

            do eID = 1, mesh % no_of_elements
               associate( Nx => mesh % elements(eID) % Nxyz(1), &
                          Ny => mesh % elements(eID) % Nxyz(2), &
                          Nz => mesh % elements(eID) % Nxyz(3) )
               do k = 0, Nz;  do j = 0, Ny;  do i = 0, Nx

                  x     = mesh % elements(eID) % geom % x(:,i,j,k)
                  r     = sqrt(x(2)**2 + x(3)**2)
                  theta = atan2(x(3), x(2))
!                 Sum of the 120 deg images: exactly 3-fold periodic
                  decay = 0.0_RP
                  do m = -3, 3
                     decay = decay + exp(-(theta - theta0 - m*2.0_RP*PI/3.0_RP)**2 / (2.0_RP * sigma**2))
                  end do
                  uth = omega * r * decay
                  ur  = 0.05_RP * decay * sin(PI*(r - 1.0_RP)/10.0_RP)
                  ux  = 0.05_RP * decay * sin(PI*x(1))
                  uy  = ur * cos(theta) - uth * sin(theta)
                  uz  = ur * sin(theta) + uth * cos(theta)
                  rho = 1.0_RP + 0.05_RP * decay
                  p   = (1.0_RP / gammaM2) * (1.0_RP + 0.1_RP * decay)

                  q(1) = rho
                  q(2) = rho * ux
                  q(3) = rho * uy
                  q(4) = rho * uz
                  q(5) = p/(gamma - 1.0_RP) + 0.5_RP * rho * (ux**2 + uy**2 + uz**2)

                  mesh % elements(eID) % storage % q(:,i,j,k) = q
               end do;        end do;        end do
"""

def problem_file():
    src = open(os.path.join(TEST, 'SETUP', 'ProblemFile.f90')).read()
    src = src.replace('            real(kind=RP)  :: uy, uz\n',
                      '            real(kind=RP)  :: uy, uz, ux, ur, uth, r\n            integer        :: m\n', 1)
    a = src.index('            omega  = 0.1_RP')
    b = src.index('               end do;        end do;        end do\n', a) + len('               end do;        end do;        end do\n')
    src = src[:a] + IC + src[b:]
    # no asserts: these runs are compared against each other
    a = src.index('            real(kind=RP), parameter :: residuals(5)')
    b = src.index('            CALL detachSharedAssertionsManager') + len('            CALL detachSharedAssertionsManager\n')
    src = src[:a] + '            write(STD_OUT,*) "validation run, no asserts"\n' + src[b:]
    return src

# ---------------------------------------------------------------- control files
PROBES = [(0.5, 3.0, 1.0), (0.5, 3.0, 30.0), (0.5, 3.0, 60.0), (0.5, 3.0, 119.0),
          (0.5, 6.0, 0.5), (0.5, 6.0, 119.5), (0.3, 10.5, 2.0), (0.7, 1.5, 118.0)]
VARS = ['pressure', 'u', 'v', 'w']

def control(name, mesh, periodic, viscous='BR1', gradvars=None, equations='NS', axis='[1.0,0.0,0.0]',
            steps=200, extra='', bcs=None):
    c = f"""Flow equations        = "{equations}"
mesh file name        = "MESH/{mesh}.msh"
Polynomial order      = 2
Number of time steps  = {steps}
Output Interval       = 20
Convergence tolerance = 1.d-10
dt                    = 1.5d-3
mach number           = 0.3
Reynolds number       = 10.0
AOA theta             = 0.0
AOA phi               = 90.0
solution file name    = "RESULTS/{name}.hsol"
restart               = .false.
restart file name     = "RESULTS/none.hsol"
Number of plot points = 5
riemann solver        = roe
Discretization nodes  = Gauss-Lobatto
viscous discretization = {viscous}
simulation type       = time-accurate
autosave mode         = "iteration"
autosave interval     = 100000
partitioning          = SFC
"""
    if gradvars:
        c += f'gradient variables    = {gradvars}\n'
    if periodic:
        c += f"""periodic enabled      = .true.
rotation axis         = {axis}
rotation center       = [0.0,0.0,0.0]
"""
    c += extra
    if bcs is not None:
        c += bcs
    else:
        for b in ['inflow', 'outflow', 'top', 'bottom']:
            c += f'\n#define boundary {b}\n  type = FreeSlipWall\n#end\n'
        if periodic:
            c += '\n#define boundary sideb\n  type = Periodic\n  coupled boundary = sidea\n#end\n'
            c += '\n#define boundary sidea\n  type = Periodic\n  coupled boundary = sideb\n#end\n'
    k = 0
    for (x, r, th) in PROBES:
        t = math.radians(th)
        for v in VARS:
            k += 1
            c += (f'\n#define probe {k}\n   Name = p{k:02d}_{v}\n'
                  f'   Position = [{x:.6f},{r*math.cos(t):.12f},{r*math.sin(t):.12f}]\n   Variable = {v}\n#end\n')
    return c

VARIANTS = {   # name: (viscous, gradvars, equations)
    'br1':     ('BR1', None, 'NS'),
    'br2':     ('BR2', None, 'NS'),
    'ip':      ('IP', None, 'NS'),
    'entropy': ('BR1', 'Entropy', 'NS'),
    'energy':  ('BR1', 'Energy', 'NS'),
    'euler':   ('BR1', None, 'Euler'),
}

def main():
    os.makedirs(os.path.join(HERE, 'MESH'), exist_ok=True)
    os.makedirs(os.path.join(HERE, 'SETUP'), exist_ok=True)
    open(os.path.join(HERE, 'MESH', 'sector.geo'), 'w').write(SECTOR)
    open(os.path.join(HERE, 'MESH', 'annulus.geo'), 'w').write(ANNULUS)
    open(os.path.join(HERE, 'SETUP', 'ProblemFile.f90'), 'w').write(problem_file())
    shutil.copy(os.path.join(TEST, 'SETUP', 'Makefile'), os.path.join(HERE, 'SETUP', 'Makefile'))
    if not os.path.lexists(os.path.join(HERE, 'horses3d.ns')):
        os.symlink(BIN, os.path.join(HERE, 'horses3d.ns'))
    for v, (visc, gv, eq) in VARIANTS.items():
        open(os.path.join(HERE, f'sector-{v}.control'), 'w').write(
            control(f'sector-{v}', 'sector', True, visc, gv, eq))
        open(os.path.join(HERE, f'annulus-{v}.control'), 'w').write(
            control(f'annulus-{v}', 'annulus', False, visc, gv, eq))
    # same physics, rotation axis written as -x (same geometry, must give the same answer)
    open(os.path.join(HERE, 'sector-br1-flip.control'), 'w').write(
        control('sector-br1-flip', 'sector', True, axis='[-1.0,0.0,0.0]'))
    # two periodic pairs (each side split at r = 6); zone order decides which side is the master
    bcs = '\n#define boundary walls\n  type = FreeSlipWall\n#end\n'
    for a, b in [('sidea_in', 'sideb_in'), ('sideb_in', 'sidea_in'), ('sidea_out', 'sideb_out'), ('sideb_out', 'sidea_out')]:
        bcs += f'\n#define boundary {a}\n  type = Periodic\n  coupled boundary = {b}\n#end\n'
    for m in ['twopairs', 'twopairs-ok']:
        open(os.path.join(HERE, f'{m}-br1.control'), 'w').write(control(f'{m}-br1', m, True, bcs=bcs))

if __name__ == '__main__':
    main()
