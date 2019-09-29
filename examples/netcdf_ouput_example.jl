using Oceananigans, Printf

####
#### Model set-up
####

Nx, Ny, Nz = 16, 16, 16       # No. of grid points in x, y, and z, respectively.
Lx, Ly, Lz = 100, 100, 100    # Length of the domain in x, y, and z, respectively.
tf = 5000

model = Model(grid=RegularCartesianGrid(N=(Nx, Ny, Nz), L=(Lx, Ly, Lz)),
              closure=ConstantIsotropicDiffusivity())

# Add a cube-shaped warm temperature anomaly that takes up the middle 50%
# of the domain volume.
i1, i2 = round(Int, Nx/4), round(Int, 3Nx/4)
j1, j2 = round(Int, Ny/4), round(Int, 3Ny/4)
k1, k2 = round(Int, Nz/4), round(Int, 3Nz/4)
model.tracers.T.data[i1:i2, j1:j2, k1:k2] .+= 0.01

####
#### Set up output
####

write_grid(model)
subsetwriter = NetCDFOutputWriter(model,
                                  Dict("v"=>model.velocities.v,
                                       "u"=>model.velocities.u,
                                       "w"=>model.velocities.w,
                                       "T"=>model.tracers.T,
                                       "S"=>model.tracers.S),
                                  interval=10, filename="dump_subset.nc",
                                  xC=2:Nx-1, xF=2:Nx-1, yC=2:Ny-1,
                                  yF=2:Ny-1, zC=2:Nz-1, zF=2:Nz-1)
push!(model.output_writers, subsetwriter)

# TODO: Writing global output fails right now. The lengths of the
# dimensions are not equal to the lengths of the field arrays due to
# halo regions. This needs to be discussed.
# globalwriter = NetCDFOutputWriter(model,
#                                   Dict("v"=>model.velocities.v,
#                                        "u"=>model.velocities.u,
#                                        "w"=>model.velocities.w,
#                                        "T"=>model.tracers.T,
#                                        "S"=>model.tracers.S),
#                                   interval=10, filename="dump_global.nc")
# push!(model.output_writers, globalwriter)

####
#### Run the simulation
####

function terse_message(model, walltime, Δt)
    cfl = Δt / Oceananigans.cell_advection_timescale(model)
    return @sprintf("i: %d, t: %.4f hours, Δt: %.1f s, cfl: %.3f, wall time: %s\n",
                    model.clock.iteration, model.clock.time/3600, Δt, cfl, prettytime(walltime))
end

# A wizard for managing the simulation time-step.
wizard = TimeStepWizard(cfl=0.2, Δt=1.0, max_change=1.1, max_Δt=50.0)

# Run the model
while model.clock.time < tf
    update_Δt!(wizard, model)
    walltime = @elapsed time_step!(model, 10, wizard.Δt)
    @printf "%s" terse_message(model, walltime, wizard.Δt)
end

# Close the NetCDFOutputWriter
OWClose(subsetwriter)
#OWClose(globalwriter)
