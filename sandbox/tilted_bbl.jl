using Oceananigans
using Oceananigans.Units
using Oceananigans.TurbulenceClosures: AnisotropicMinimumDissipation
using CUDA

const Nx = 450; const Lx = 1000
const Nz = 64; const Lz = 100
const θ_rad = 0.05 # radians
const θ_deg = rad2deg(θ_rad) # degrees
const N²∞ = 1e-5
const V∞ = 0.1
const g̃ = (sin(θ_rad), 0, cos(θ_rad))

#++++ Grid
topo = (Periodic, Periodic, Bounded)

S = 1.3
zF(k) = Lz*(1 + tanh(S * ( (k - 1) / Nz - 1)) / tanh(S))
grid = VerticallyStretchedRectilinearGrid(topology=topo,
                                          architecture = CUDA.has_cuda() ? GPU() : CPU(), 
                                          size=(Nx, 1, Nz), 
                                          x=(0, Lx), y=(0, 6*Lx/Nx), zF=zF,
                                          halo=(3,1,3),
                                         )
println(); println(grid); println()
#----

#++++ Buoyancy model and background
buoyancy = Buoyancy(model=BuoyancyTracer(), gravitational_unit_vector=g̃)
tracers = :b

b∞(x, y, z, t) = N²∞ * (x*g̃[1] + z*g̃[3])
B_field = BackgroundField(b∞)

b_bottom(x, y, t) = -b∞(x, y, 0, t)
grad_bc_b = GradientBoundaryCondition(b_bottom)
b_bcs = TracerBoundaryConditions(grid, bottom = grad_bc_b)
#----

#+++++ Boundary Conditions
#+++++ Bottom Drag
const z₀ = 0.01 # roughness length (m)
const κ = 0.4 # von Karman constant
const cᴰ = (κ / log(grid.zᵃᵃᶜ[1]))^2 # quadratic drag coefficient

@inline drag_u(x, y, t, u, v, cᴰ) = - cᴰ * √(u^2 + (v+V∞)^2) * u
@inline drag_v(x, y, t, u, v, cᴰ) = - cᴰ * √(u^2 + (v+V∞)^2) * (v + V∞)

drag_bc_u = FluxBoundaryCondition(drag_u, field_dependencies=(:u, :v), parameters=cᴰ)
drag_bc_v = FluxBoundaryCondition(drag_v, field_dependencies=(:u, :v), parameters=cᴰ)

u_bcs = UVelocityBoundaryConditions(grid, bottom = drag_bc_u)
v_bcs = VVelocityBoundaryConditions(grid, bottom = drag_bc_v)

V_bg(x, y, z, t) = V∞
V_field = BackgroundField(V_bg)
#-----

ybc = GradientBoundaryCondition(0)
zbc = GradientBoundaryCondition(0)
bcs = (u=u_bcs,
       v=v_bcs,
       b=b_bcs,
       )
#-----


#++++ Model and ICs
model = IncompressibleModel(grid = grid, timestepper = :RungeKutta3,
                            advection = WENO5(),
                            buoyancy = buoyancy,
                            coriolis = FPlane(f=1e-4),
                            tracers = tracers,
                            closure = AnisotropicMinimumDissipation(),
                            #closure = IsotropicDiffusivity(ν=1e-4, κ=1e-4),
                            boundary_conditions = bcs,
                            background_fields = (b=B_field, v=V_field,),
                           )
println(); println(model); println()

noise(z, kick) = kick * randn() * exp(-z / 10)
u_ic(x, y, z) = noise(z, 1e-3)
set!(model, b=0, u=u_ic, v=u_ic)

ū = sum(model.velocities.u.data.parent) / (grid.Nx * grid.Ny * grid.Nz)
v̄ = sum(model.velocities.v.data.parent) / (grid.Nx * grid.Ny * grid.Nz)

model.velocities.u.data.parent .-= ū
model.velocities.v.data.parent .-= v̄
#----

#++++ Create simulation
wizard = TimeStepWizard(Δt=0.1*grid.Δzᵃᵃᶜ[1]/V∞, max_change=1.05, cfl=0.2)
print_progress(sim) = @info "iteration: $(sim.model.clock.iteration), time: $(prettytime(sim.model.clock.time))"
simulation = Simulation(model, Δt=wizard, 
                        stop_time=10days, 
                        progress=print_progress, 
                        iteration_interval=10,
                        stop_iteration=Inf,
                       )
#----


if true
    b_tot = ComputedField(model.tracers.b + model.background_fields.tracers.b)
    v_tot = ComputedField(model.velocities.v + model.background_fields.velocities.v)
    fields = merge(model.velocities, model.tracers, (; b_tot, v_tot,))
    simulation.output_writers[:fields] =
    NetCDFOutputWriter(model, fields, filepath = "out.tilted_bbl.nc",
                       schedule = TimeInterval(5minutes),
                       mode = "c")
end

run!(simulation)
