using Oceananigans 
using Oceananigans.Models
using Profile
using Oceananigans.Grids: halo_size

Nx = 4

topologies = (  (Periodic, Periodic, Bounded), 
                (Periodic, Periodic, Flat),
                (Periodic, Flat,     Flat),    
                (Flat,     Flat,     Flat)
                )
sizes = ( (Nx,Nx,1), 
          (Nx, Nx), 
          (Nx), 
          () 
          )
extents = ( (1, 1, 1), 
            (1, 1), 
            (1), 
            ()
            ) 

halos = ( (3, 3, 3),
          (3, 3),
          (3),
          ())

Grids = RegularLatitudeLongitudeGrid
#Grids = RegularRectilinearGrid

for (iter, topo) in enumerate(topologies)

    grid = RegularRectilinearGrid(size=sizes[iter], extent=extents[iter], topology=topo, halo=halos[iter])
    #grid = RegularLatitudeLongitudeGrid(size=sizes[iter], longitude=(0, 60), latitude=(15, 75), topology=topo, halo=halos[iter])

    model = ShallowWaterModel(architecture=CPU(), grid=grid, advection=WENO5(), gravitational_acceleration=1)

    set!(model,h=1)

    simulation = Simulation(model, Δt = 1e-3, stop_time = 1e-2)

    run!(simulation)
    
    print("Successfully completed case with topology = ", topo, "\n\n")
end
