@hascuda using GPUifyLoops, CUDAnative, CuArrays

using Oceananigans.Operators

function time_step!(model::Model; Nt, Δt)
    if model.metadata.arch == :cpu
        time_step_kernel_cpu!(model, Nt, Δt)
    elseif model.metadata.arch == :gpu
        time_step_kernel_gpu!(model, Nt, Δt)
    end
end

function time_step_kernel_cpu!(model::Model, Nt, Δt)
    metadata = model.metadata
    cfg = model.configuration
    bc = model.boundary_conditions
    g = model.grid
    c = model.constants
    eos = model.eos
    ssp = model.ssp
    U = model.velocities
    tr = model.tracers
    pr = model.pressures
    G = model.G
    Gp = model.Gp
    F = model.forcings
    stmp = model.stepper_tmp
    clock = model.clock

    model_start_time = clock.time
    model_end_time = model_start_time + Nt*Δt

    if clock.time_step == 0
        for output_writer in model.output_writers
            write_output(model, output_writer)
        end
        for diagnostic in model.diagnostics
            run_diagnostic(model, diagnostic)
        end
    end

    Nx, Ny, Nz = g.Nx, g.Ny, g.Nz
    Lx, Ly, Lz = g.Lx, g.Ly, g.Lz
    Δx, Δy, Δz = g.Δx, g.Δy, g.Δz

    # Field references.
    δρ = stmp.fC1
    RHS = stmp.fCC1
    ϕ   = stmp.fCC2

    # Constants.
    gΔz = c.g * g.Δz
    χ = 0.1  # Adams-Bashforth (AB2) parameter.
    fCor = c.f

    for n in 1:Nt
        t1 = time_ns(); # Timing the time stepping loop.

        update_buoyancy!(Val(:CPU), gΔz, Nx, Ny, Nz, tr.ρ.data, δρ.data, tr.T.data, pr.pHY′.data, eos.ρ₀, eos.βT, eos.T₀)

        update_source_terms!(Val(:CPU), fCor, χ, eos.ρ₀, cfg.κh, cfg.κv, cfg.𝜈h, cfg.𝜈v, Nx, Ny, Nz, Δx, Δy, Δz,
                             U.u.data, U.v.data, U.w.data, tr.T.data, tr.S.data, pr.pHY′.data,
                             G.Gu.data, G.Gv.data, G.Gw.data, G.GT.data, G.GS.data,
                             Gp.Gu.data, Gp.Gv.data, Gp.Gw.data, Gp.GT.data, Gp.GS.data, model.forcing)

        calculate_source_term_divergence_cpu!(Val(:CPU), Nx, Ny, Nz, Δx, Δy, Δz, G.Gu.data, G.Gv.data, G.Gw.data, RHS.data)

        solve_poisson_3d_ppn_planned!(ssp, g, RHS, ϕ)
        @. pr.pNHS.data = real(ϕ.data)

        update_velocities_and_tracers!(Val(:CPU), Nx, Ny, Nz, Δx, Δy, Δz, Δt,
                                       U.u.data, U.v.data, U.w.data, tr.T.data, tr.S.data, pr.pNHS.data,
                                       G.Gu.data, G.Gv.data, G.Gw.data, G.GT.data, G.GS.data,
                                       Gp.Gu.data, Gp.Gv.data, Gp.Gw.data, Gp.GT.data, Gp.GS.data)

        clock.time += Δt
        clock.time_step += 1
        print("\rmodel.clock.time = $(clock.time) / $model_end_time   ")

        for output_writer in model.output_writers
            if clock.time_step % output_writer.output_frequency == 0
                write_output(model, output_writer)
            end
        end

        for diagnostic in model.diagnostics
            if clock.time_step % diagnostic.diagnostic_frequency == 0
                run_diagnostic(model, diagnostic)
            end
        end

        t2 = time_ns();
        println(prettytime(t2 - t1))
    end
end

function time_step_kernel_gpu!(model::Model, Nt, Δt)
    metadata = model.metadata
    cfg = model.configuration
    bc = model.boundary_conditions
    g = model.grid
    c = model.constants
    eos = model.eos
    ssp = model.ssp
    U = model.velocities
    tr = model.tracers
    pr = model.pressures
    G = model.G
    Gp = model.Gp
    F = model.forcings
    stmp = model.stepper_tmp
    clock = model.clock

    model_start_time = clock.time
    model_end_time = model_start_time + Nt*Δt

    if clock.time_step == 0
        for output_writer in model.output_writers
            write_output(model, output_writer)
        end
        for diagnostic in model.diagnostics
            run_diagnostic(model, diagnostic)
        end
    end

    Nx, Ny, Nz = g.Nx, g.Ny, g.Nz
    Lx, Ly, Lz = g.Lx, g.Ly, g.Lz
    Δx, Δy, Δz = g.Δx, g.Δy, g.Δz

    # Field references.
    δρ = stmp.fC1
    RHS = stmp.fCC1
    ϕ   = stmp.fCC2

    # Constants.
    gΔz = c.g * g.Δz
    χ = 0.1  # Adams-Bashforth (AB2) parameter.
    fCor = c.f

    Tx, Ty = 16, 16  # Threads per block
    Bx, By, Bz = Int(Nx/Tx), Int(Ny/Ty), Nz  # Blocks in grid.

    println("Threads per block: ($Tx, $Ty)")
    println("Blocks in grid:    ($Bx, $By, $Bz)")

    for n in 1:Nt
        t1 = time_ns(); # Timing the time stepping loop.

        @hascuda @cuda threads=(Tx, Ty) blocks=(Bx, By, Bz) update_buoyancy!(Val(:GPU), gΔz, Nx, Ny, Nz, tr.ρ.data, δρ.data, tr.T.data, pr.pHY′.data, eos.ρ₀, eos.βT, eos.T₀)

        @hascuda @cuda threads=(Tx, Ty) blocks=(Bx, By, Bz) update_source_terms!(Val(:GPU), fCor, χ, eos.ρ₀, cfg.κh, cfg.κv, cfg.𝜈h, cfg.𝜈v, Nx, Ny, Nz, Δx, Δy, Δz,
                                                                                 U.u.data, U.v.data, U.w.data, tr.T.data, tr.S.data, pr.pHY′.data,
                                                                                 G.Gu.data, G.Gv.data, G.Gw.data, G.GT.data, G.GS.data,
                                                                                 Gp.Gu.data, Gp.Gv.data, Gp.Gw.data, Gp.GT.data, Gp.GS.data, F.FT.data)

        @hascuda @cuda threads=(Tx, Ty) blocks=(Bx, By, Bz) calculate_source_term_divergence_gpu!(Val(:GPU), Nx, Ny, Nz, Δx, Δy, Δz, G.Gu.data, G.Gv.data, G.Gw.data, RHS.data)

        solve_poisson_3d_ppn_gpu_planned!(Tx, Ty, Bx, By, Bz, model.ssp, g, RHS, ϕ)
        @hascuda @cuda threads=(Tx, Ty) blocks=(Bx, By, Bz) idct_permute!(Val(:GPU), Nx, Ny, Nz, ϕ.data, pr.pNHS.data)

        @hascuda @cuda threads=(Tx, Ty) blocks=(Bx, By, Bz) update_velocities_and_tracers!(Val(:GPU), Nx, Ny, Nz, Δx, Δy, Δz, Δt,
                                                                                           U.u.data, U.v.data, U.w.data, tr.T.data, tr.S.data, pr.pNHS.data,
                                                                                           G.Gu.data, G.Gv.data, G.Gw.data, G.GT.data, G.GS.data,
                                                                                           Gp.Gu.data, Gp.Gv.data, Gp.Gw.data, Gp.GT.data, Gp.GS.data)

        clock.time += Δt
        clock.time_step += 1
        print("\rmodel.clock.time = $(clock.time) / $model_end_time   ")

        for output_writer in model.output_writers
            if clock.time_step % output_writer.output_frequency == 0
                write_output(model, output_writer)
            end
        end

        for diagnostic in model.diagnostics
            if clock.time_step % diagnostic.diagnostic_frequency == 0
                run_diagnostic(model, diagnostic)
            end
        end

        t2 = time_ns();
        println(prettytime(t2 - t1))
    end
end

@inline δρ(eos::LinearEquationOfState, T::CellField, i, j, k) = - eos.ρ₀ * eos.βT * (T.data[i, j, k] - eos.T₀)
@inline δρ(ρ₀, βT, T₀, T, i, j, k) = @inbounds -ρ₀ * βT * (T[i, j, k] - T₀)

function update_buoyancy!(::Val{Dev}, gΔz, Nx, Ny, Nz, ρ, δρ, T, pHY′, ρ₀, βT, T₀) where Dev
    @setup Dev

    @loop for k in (1:Nz; blockIdx().z)
        @loop for j in (1:Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                @inbounds δρ[i, j, k] = -ρ₀*βT * (T[i, j, k] - T₀)
                @inbounds  ρ[i, j, k] = ρ₀ + δρ[i, j, k]

                ∫δρ = (-ρ₀*βT*(T[i, j, 1]-T₀))
                for k′ in 2:k
                    ∫δρ += ((-ρ₀*βT*(T[i, j, k′-1]-T₀)) + (-ρ₀*βT*(T[i, j, k′]-T₀)))
                end
                @inbounds pHY′[i, j, k] = 0.5 * gΔz * ∫δρ
            end
        end
    end

    @synchronize
end

function update_source_terms!(::Val{Dev}, fCor, χ, ρ₀, κh, κv, 𝜈h, 𝜈v, Nx, Ny, Nz, Δx, Δy, Δz, u, v, w, T, S, pHY′, Gu, Gv, Gw, GT, GS, Gpu, Gpv, Gpw, GpT, GpS, F) where Dev
    @setup Dev

    @loop for k in (1:Nz; blockIdx().z)
        @loop for j in (1:Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                @inbounds Gpu[i, j, k] = Gu[i, j, k]
                @inbounds Gpv[i, j, k] = Gv[i, j, k]
                @inbounds Gpw[i, j, k] = Gw[i, j, k]
                @inbounds GpT[i, j, k] = GT[i, j, k]
                @inbounds GpS[i, j, k] = GS[i, j, k]

                @inbounds Gu[i, j, k] = -u∇u(u, v, w, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k) + fCor*avg_xy(v, Nx, Ny, i, j, k) - δx_c2f(pHY′, Nx, i, j, k) / (Δx * ρ₀) + 𝜈∇²u(u, 𝜈h, 𝜈v, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k) + F.u(u, v, w, T, S, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k)
                @inbounds Gv[i, j, k] = -u∇v(u, v, w, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k) - fCor*avg_xy(u, Nx, Ny, i, j, k) - δy_c2f(pHY′, Ny, i, j, k) / (Δy * ρ₀) + 𝜈∇²v(v, 𝜈h, 𝜈v, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k) + F.v(u, v, w, T, S, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k)
                @inbounds Gw[i, j, k] = -u∇w(u, v, w, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k)                                                                           + 𝜈∇²w(w, 𝜈h, 𝜈v, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k) + F.w(u, v, w, T, S, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k)

                @inbounds GT[i, j, k] = -div_flux(u, v, w, T, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k) + κ∇²(T, κh, κv, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k) + F.T(u, v, w, T, S, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k)
                @inbounds GS[i, j, k] = -div_flux(u, v, w, S, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k) + κ∇²(S, κh, κv, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k) + F.S(u, v, w, T, S, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k)

                @inbounds Gu[i, j, k] = (1.5 + χ)*Gu[i, j, k] - (0.5 + χ)*Gpu[i, j, k]
                @inbounds Gv[i, j, k] = (1.5 + χ)*Gv[i, j, k] - (0.5 + χ)*Gpv[i, j, k]
                @inbounds Gw[i, j, k] = (1.5 + χ)*Gw[i, j, k] - (0.5 + χ)*Gpw[i, j, k]
                @inbounds GT[i, j, k] = (1.5 + χ)*GT[i, j, k] - (0.5 + χ)*GpT[i, j, k]
                @inbounds GS[i, j, k] = (1.5 + χ)*GS[i, j, k] - (0.5 + χ)*GpS[i, j, k]
            end
        end
    end

    @synchronize
end

function calculate_source_term_divergence_cpu!(::Val{Dev}, Nx, Ny, Nz, Δx, Δy, Δz, Gu, Gv, Gw, RHS) where Dev
    @setup Dev

    @loop for k in (1:Nz; blockIdx().z)
        @loop for j in (1:Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                # Calculate divergence of the RHS source terms (Gu, Gv, Gw).
                @inbounds RHS[i, j, k] = div_f2c(Gu, Gv, Gw, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k)
            end
        end
    end

    @synchronize
end

function calculate_source_term_divergence_gpu!(::Val{Dev}, Nx, Ny, Nz, Δx, Δy, Δz, Gu, Gv, Gw, RHS) where Dev
    @setup Dev

    @loop for k in (1:Nz; blockIdx().z)
        @loop for j in (1:Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                # Calculate divergence of the RHS source terms (Gu, Gv, Gw) and applying a permutation which is the first step in the DCT.
                if CUDAnative.ffs(k) == 1  # isodd(k)
                    @inbounds RHS[i, j, convert(UInt32, CUDAnative.floor(k/2) + 1)] = div_f2c(Gu, Gv, Gw, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k)
                else
                    @inbounds RHS[i, j, convert(UInt32, Nz - CUDAnative.floor((k-1)/2))] = div_f2c(Gu, Gv, Gw, Nx, Ny, Nz, Δx, Δy, Δz, i, j, k)
                end
            end
        end
    end

    @synchronize
end

function idct_permute!(::Val{Dev}, Nx, Ny, Nz, ϕ, pNHS) where Dev
    @setup Dev

    @loop for k in (1:Nz; blockIdx().z)
        @loop for j in (1:Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                if k <= Nz/2
                    @inbounds pNHS[i, j, 2k-1] = real(ϕ[i, j, k])
                else
                    @inbounds pNHS[i, j, 2(Nz-k+1)] = real(ϕ[i, j, k])
                end
            end
        end
    end

    @synchronize
end


function update_velocities_and_tracers!(::Val{Dev}, Nx, Ny, Nz, Δx, Δy, Δz, Δt, u, v, w, T, S, pNHS, Gu, Gv, Gw, GT, GS, Gpu, Gpv, Gpw, GpT, GpS) where Dev
    @setup Dev

    @loop for k in (1:Nz; blockIdx().z)
        @loop for j in (1:Ny; (blockIdx().y - 1) * blockDim().y + threadIdx().y)
            @loop for i in (1:Nx; (blockIdx().x - 1) * blockDim().x + threadIdx().x)
                @inbounds u[i, j, k] = u[i, j, k] + (Gu[i, j, k] - (δx_c2f(pNHS, Nx, i, j, k) / Δx)) * Δt
                @inbounds v[i, j, k] = v[i, j, k] + (Gv[i, j, k] - (δy_c2f(pNHS, Ny, i, j, k) / Δy)) * Δt
                @inbounds w[i, j, k] = w[i, j, k] + (Gw[i, j, k] - (δz_c2f(pNHS, Nz, i, j, k) / Δz)) * Δt
                @inbounds T[i, j, k] = T[i, j, k] + (GT[i, j, k] * Δt)
                @inbounds S[i, j, k] = S[i, j, k] + (GS[i, j, k] * Δt)
            end
        end
    end

    @synchronize
end
