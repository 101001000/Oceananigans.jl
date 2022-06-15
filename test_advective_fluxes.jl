using Oceananigans
using Oceananigans.BoundaryConditions
using Oceananigans.ImmersedBoundaries
using Oceananigans.ImmersedBoundaries: mask_immersed_field!
using Oceananigans.Advection: VelocityStencil, VorticityStencil, WENOVectorInvariant

grid = RectilinearGrid(size = (10, 10, 1), extent = (10, 10, 1), topology = (Bounded, Bounded, Bounded))

Nx, Ny, Nz = size(grid)

boundary = zeros(Nx, Ny, Nz)
boundary[1:2, :, :] .= 1
boundary[:, 1:2, :] .= 1

ibg = ImmersedBoundaryGrid(grid, GridFittedBoundary(boundary))

model = HydrostaticFreeSurfaceModel(grid = ibg, 
                                 closure = nothing, 
                                buoyancy = nothing, 
                                 tracers = :c, 
                        tracer_advection = UpwindBiasedThirdOrder(),
                      momentum_advection = WENO3())
                    #   momentum_advection = WENO3(vector_invariant = VelocityStencil()))

u = model.velocities.u
v = model.velocities.v
w = model.velocities.w
c = model.tracers.c

set!(u, 1.0)
set!(v, -1.0)
set!(w, 1.0)
set!(c, 1.0)

wait(mask_immersed_field!(c))
wait(mask_immersed_field!(u))
wait(mask_immersed_field!(v))
wait(mask_immersed_field!(w))

fill_halo_regions!((c, u, v, w))

using Oceananigans.Advection: 
        _advective_tracer_flux_x,
        _advective_tracer_flux_y, 
        _advective_tracer_flux_z,
        div_Uc

atx = zeros(Nx, Ny, Nz)
aty = zeros(Nx, Ny, Nz)
atz = zeros(Nx, Ny, Nz)
ttC = zeros(Nx, Ny, Nz)

for i in 1:Nx, j in 1:Ny, k in 1:Nz
    atx[i, j, k] = _advective_tracer_flux_x(i, j, k, ibg, model.advection.c, u, c)
    aty[i, j, k] = _advective_tracer_flux_y(i, j, k, ibg, model.advection.c, v, c)
    atz[i, j, k] = _advective_tracer_flux_z(i, j, k, ibg, model.advection.c, w, c)
end

using Oceananigans.Advection:
      vertical_vorticity_U,
      vertical_vorticity_V,
      bernoulli_head_U,
      bernoulli_head_V,
      _advective_momentum_flux_Uu,
      _advective_momentum_flux_Vu,
      _advective_momentum_flux_Uv,
      _advective_momentum_flux_Vv

set!(u, 0.0)
set!(w, 0.0)
wait(mask_immersed_field!(u))
fill_halo_regions!((u, v))

vvU = zeros(Nx, Ny, Nz)
vvV = zeros(Nx, Ny, Nz)
diU = zeros(Nx, Ny, Nz)
diV = zeros(Nx, Ny, Nz)
ttU = zeros(Nx, Ny, Nz)
ttV = zeros(Nx, Ny, Nz)

using Oceananigans.Advection:
    U_dot_∇u,
    U_dot_∇v,
    div_𝐯u,
    div_𝐯v

if model.advection.momentum isa WENOVectorInvariant
  for i in 1:Nx, j in 1:Ny, k in 1:Nz
    vvU[i, j, k] = vertical_vorticity_U(i, j, k, ibg, model.advection.momentum, u, v)
    vvV[i, j, k] = vertical_vorticity_V(i, j, k, ibg, model.advection.momentum, u, v)
    diU[i, j, k] = bernoulli_head_U(i, j, k, ibg, model.advection.momentum, u, v)
    diV[i, j, k] = bernoulli_head_V(i, j, k, ibg, model.advection.momentum, u, v)
    ttU[i, j, k] = U_dot_∇u(i, j, k, ibg, model.advection.momentum, (; u, v, w))
    ttV[i, j, k] = U_dot_∇v(i, j, k, ibg, model.advection.momentum, (; u, v, w))
  end
else
  for i in 1:Nx, j in 1:Ny, k in 1:Nz
    vvU[i, j, k] = _advective_momentum_flux_Uu(i, j, k, ibg, model.advection.momentum, u, u) + _advective_momentum_flux_Vu(i, j, k, ibg, model.advection.momentum, v, u)
    vvV[i, j, k] = _advective_momentum_flux_Uv(i, j, k, ibg, model.advection.momentum, u, v) + _advective_momentum_flux_Vv(i, j, k, ibg, model.advection.momentum, v, v)
    ttU[i, j, k] = div_𝐯u(i, j, k, ibg, model.advection.momentum, (; u, v, w), u)
    ttV[i, j, k] = div_𝐯v(i, j, k, ibg, model.advection.momentum, (; u, v, w), v)
  end
end