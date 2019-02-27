using Pkg; Pkg.activate("."); Pkg.instantiate()

using 
    Plots, 
    PyPlot, 
    FFTW, 
    Oceananigans

function make_temperature_movie(model::Model, fw::NetCDFFieldWriter)
    n_frames = Int(model.clock.time_step / fw.output_frequency)

    xC, yC, zC = model.grid.xC, model.grid.yC, model.grid.zC

    print("Creating temperature movie... ($n_frames frames)\n")

    Plots.gr()
    default(dpi=300)
    movie = @animate for tidx in 0:n_frames
        print("\rframe = $tidx / $n_frames   ")
        temperature = read_output(model, fw, "T", tidx*fw.output_frequency*model.clock.Δt)
        Plots.heatmap(xC, zC, rotl90(temperature[:, Int(ceil(model.grid.Ny/2)), :]) .- 283, color=:balance,
                      clims=(-0.5, 0.5), aspect_ratio=:equal,
                      title="T @ t=$(tidx*fw.output_frequency*model.clock.Δt)")
    end

    mp4(movie, "rayleigh_benard_$(round(Int, time())).mp4", fps = 30)
end

function plot_Nusselt_number_diagnostics(model::Model, Nu_wT_diag::Nusselt_wT, Nu_Chi_diag::Nusselt_Chi)
    println("Plotting Nusselt number diagnostics...")

    Nx, Ny, Nz = model.grid.Nx, model.grid.Ny, model.grid.Nz
    t = 0:model.clock.Δt:model.clock.time

    PyPlot.plot(t, Nu_wT_diag.Nu, label="Nu_wT")
    PyPlot.plot(t, Nu_wT_diag.Nu_inst, label="Nu_wT_inst")
    PyPlot.plot(t, Nu_Chi_diag.Nu, label="Nu_Chi")
    PyPlot.plot(t, Nu_Chi_diag.Nu_inst, label="Nu_Chi_inst")

    PyPlot.title("Rayleigh–Bénard convection ($Nx×$Ny×$Nz) @ Ra=5000")
    PyPlot.xlabel("Time (s)")
    PyPlot.ylabel("Nusselt number Nu")
    PyPlot.legend()
    PyPlot.savefig("rayleigh_benard_nusselt_diag.png", dpi=300, format="png", transparent=false)
end

Nx = 512
Ny = 1
Nz = 256
Lx = 500.0
Ly = 500.0
Lz = 500.0
Nt = 100
Δt = 0.1
ν, κ = 1e-2, 1e-2

model = Model((Nx, Ny, Nz), (Lx, Ly, Lz))

α = 207e-6  # Volumetric expansion coefficient [K⁻¹] of water at 20°C.
ΔT = 1      # Temperature difference [K] between top and bottom.
Pr = 0.7    # Prandtl number Pr = 𝜈/κ.

model.configuration = _ModelConfiguration(ν, ν, κ, κ)
model.boundary_conditions = BoundaryConditions(:periodic, :periodic, :rigid_lid, :no_slip)

# Write temperature field to disk every 10 time steps.
output_dir, output_prefix, output_freq = ".", "rayleigh_benard", 10
field_writer = NetCDFFieldWriter(output_dir, output_prefix, output_freq) #, [model.tracers.T], ["T"])
push!(model.output_writers, field_writer)

diag_freq, Nu_running_avg = 1, 0
Nu_wT_diag = Nusselt_wT(diag_freq, Float64[], Float64[], Nu_running_avg)
push!(model.diagnostics, Nu_wT_diag)

Nu_Chi_diag = Nusselt_Chi(diag_freq, Float64[], Float64[], Nu_running_avg)
push!(model.diagnostics, Nu_Chi_diag)

# Small random perturbations are added to boundary conditions to ensure instability formation.
top_T    = 283 .- (ΔT/2) .+ 0.001.*rand(Nx, Ny)
bottom_T = 283 .+ (ΔT/2) .+ 0.001.*rand(Nx, Ny)

for i in 1:Nt
    time_step!(model; Nt=1, Δt=Δt)
    # Impose constant T boundary conditions at top and bottom every time step.
    #@. model.tracers.T.data[:, :,   1] = top_T
    #@. model.tracers.T.data[:, :, end] = bottom_T
end

make_temperature_movie(model, field_writer)
plot_Nusselt_number_diagnostics(model, Nu_wT_diag, Nu_Chi_diag)
