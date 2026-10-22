Mesh.MshFileVersion = 4.1;
N = 16; Nx = 5; Na = 30;
l1=1.0; l2=10.0; Lx=1.0; c1 = 1.0;
Point(1) = {0.0, 0.0, 0.0, c1};
Point(2) = {0.0, l1, 0.0, c1};
line[] = Extrude {0.0, l2, 0.0} { Point{2}; Layers{N}; };
surface[] = Extrude {Lx, 0.0, 0.0} { Line{line[1]}; Layers{Nx}; Recombine; };

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
