#=
        !!! Still in early development !!!

    Solves the Landau-Lifshitz-Gilbert equation, using an
    implicit midpoint rule, inspired by
     https://doi.org/10.1016/j.jcp.2021.110142

    The method of calculating the demag field is adapted from
     https://doi.org/10.1016/j.jmmm.2012.01.016

    The exchange field calculation is inpired by both
        https://doi.org/10.1109/TMAG.2008.2001666
        and
        https://doi.org/10.1016/S0927-0256(03)00119-8
=#

# For plots
# using GLMakie

include("../gmsh_wrapper.jl")
# include("LandauLifshitz.jl")
include("../FEM.jl")

function EulerStep(m::Vector{Float64}, H::Vector{Float64}, dt::Float64, damp::Float64 = 1.0)
    # New magnetization direction from Forward Euler method
    mat::Matrix{Float64} = [1 damp*m[3] -damp*m[2];
                            -damp*m[3] 1 damp*m[1];
                            damp*m[2] -damp*m[1] 1]

    mNew::Vector{Float64} = mat\(m - dt.*cross(m,H))
    return mNew./norm(mNew)
end

# Yang 2021, time step predictor-corrector iteration scheme
function YangStep(m::Vector{Float64}, mOld::Vector{Float64}, H::Vector{Float64}, Hold::Vector{Float64}, dt::Float64, damp::Float64=1.0)
    # m (n-1/2)
    mOld2::Vector{Float64} = 0.5.*(m+mOld)

    # m (n+1) | Initial Forward Euler prediciton 
    mPred::Vector{Float64} = EulerStep(m,H,dt,damp)

    # m (n+1/2) | from Euler
    m12::Vector{Float64} = mPred + 3.0.*m - mOld2   # From Yang 2021
    # m12::Vector{Float64} = 0.5.*(mPred + m)       # Simpler expression

    # H (n+1/2)
    H12::Vector{Float64} = 3/2 .*H - 0.5.*Hold

    # Run the predictor-corrector iteration method
    err::Float64 = 1.0
    att::Int32 = 0
    while err > 1e-5 && att < 10
        mat::Matrix{Float64} = [1 damp*m12[3] -damp*m12[2];
                                -damp*m12[3] 1 damp*m12[1];
                                damp*m12[2] -damp*m12[1] 1]

        mNew::Vector{Float64} = mat\(m-cross(m12,damp.*m + dt.*H12))
        
        # println("m(n+1): ",mNew)
        err = norm(mNew-mPred)
        att += 1
        println(err)
        println("|m| = ",norm(mNew))

        # Update to the last solution
        mPred = deepcopy(mNew)
        m12 = mPred + 3.0.*m - mOld2    # From Yang 2021
        # m12 = 0.5.*(mPred + m)        # Simpler expression
    end # Predictor-corrector

    return mPred
end # Yang 2021, time step predictor-corrector iteration scheme

function test()

    dt::Float64 = 0.1
    damp::Float64 = 1.0

    # m (n-1)
    mOld::Vector{Float64} = 2.0.*rand(3) .- 1
    mOld ./= norm(mOld)
    
    # H (n-1)
    HeffOld::Vector{Float64} = 2.0.*rand(3) .- 1

    # m (n)
    m::Vector{Float64} = 2.0.*rand(3) .- 1
    m ./= norm(m)
    println("m(n): ",m)

    # H (n)
    Heff::Vector{Float64} = 2.0.*rand(3) .- 1

    # m (n+1)
    mNew::Vector{Float64} = YangStep(m,mOld,Heff,HeffOld,dt,damp)

    println("H(n): ",Heff)
    println("m(n+1): ",mNew)

end

test()



function main()
    meshSize::Float64 = 0

    # Constants
    mu0::Float64 = pi*4e-7          # vacuum magnetic permeability
    giro::Float64 = 2.210173e5 /mu0 # Gyromagnetic ratio (rad T-1 s-1)
    dt::Float64 = 0.01              # Time step (giro * s)
    totalTime::Float64 = 0.4        # Total time of spin dynamics simulation (ns)
    damp::Float64 = 0.1             # Damping parameter (dimensionless [0,1])
    precession::Float64 = 1.0       # Include precession or not (0 or 1)

    # Dimension of the magnetic material 
    L::Vector{Float64} = [100,100,5] # [512,128,30]
    scl::Float64 = 1e-9                 # scale of the geometry | (m -> nm)
    
    # Conditions
    Ms::Float64   = 860e3               # Magnetic saturation (A/m)
    Aexc::Float64 = 13e-12              # Exchange   (J/m)
    Aan::Float64  = 0                   # Anisotropy (J/m3)
    uan::Vector{Float64}  = [1,0,0]     # easy axis direction
    Hap::Vector{Float64}  = [0,50e3,0] # A/m

    # Convergence criteria | Only used when totalTime != Inf
    maxTorque::Float64 = 0              # Maximum difference between current and previous <M>
    maxAtt::Int32 = 15_000              # Maximum number of iterations in the solver
    
    # -- Create a geometry --
    gmsh.initialize()

    # Magnetic body
    # addSphere([0,0,0],50)
    addCuboid([0,0,0],L)

    # Generate Mesh
    mesh = Mesh([],meshSize,0,false)

    # Finalize Gmsh and show mesh properties
    # gmsh.fltk.run()
    gmsh.finalize()
        
    # -----------------------

    println("Number of elements ",size(mesh.t,2))
    println("Number of Inside elements ",length(mesh.InsideElements))
    println("Number of nodes ",size(mesh.p,2))
    println("Number of Inside nodes ",length(mesh.InsideNodes))
    println("Number of surface elements ",size(mesh.surfaceT,2))
    # viewMesh(mesh)
    # return

    # Pre-calculate the area of each surface triangle
    areaT::Vector{Float64} = zeros(mesh.ne)
    for s in 1:mesh.ne
        nds = mesh.surfaceT[1:3,s]
        areaT[s] = areaTriangle(mesh.p[1,nds],mesh.p[2,nds],mesh.p[3,nds])
    end

    # Volume of elements of each mesh node | Needed for the demagnetizing field
    Vn::Vector{Float64} = zeros(mesh.nv)

    # Integral of basis function over the domain | Needed for the exchange field
    nodeVolume::Vector{Float64} = zeros(mesh.nv)
    
    for k in 1:mesh.nt
        Vn[mesh.t[:,k]]         .+= mesh.VE[k]
        nodeVolume[mesh.t[:,k]] .+= mesh.VE[k]/4
    end

    # FEM/BEM matrices
    A = denseStiffnessMatrix(mesh)  # ij
    B = Bmatrix(mesh, areaT)        # in
    C = Cmatrix(mesh, areaT)        # mj
    D = Dmatrix(mesh, areaT)        # mn

    LHS::Matrix{Float64} = [-A B; C D]; # Final BEM matrix

    # Initial magnetization field
    m::Matrix{Float64} = zeros(3,mesh.nv)
    m[1,:] .= 1

    # Landau Lifshitz
    m, Heff, M_avg, E_time, torque_time = LandauLifshitz(mesh, m, Ms,
                                                        Hap, Aexc, Aan,
                                                        uan, scl, damp, giro,
                                                        A, LHS, Vn, nodeVolume, areaT,
                                                        dt, precession, maxTorque,
                                                        maxAtt, totalTime)

    time::Vector{Float64} = 1e9*dt .* (1:size(M_avg,2))

    fig = Figure()
    ax = Axis(  fig[1,1],
                xlabel = "Time (ns)", 
                ylabel = "<M> (kA/m)",
                title = "Micromagnetic simulation",
                yticks = range(-1500,1500,5))

    scatter!(ax,time,Ms/1000 .*M_avg[1,:], label = "M_x")
    scatter!(ax,time,Ms/1000 .*M_avg[2,:], label = "M_y")
    scatter!(ax,time,Ms/1000 .*M_avg[3,:], label = "M_z")
    axislegend()

    # save("M_time_Sphere.png",fig)
    wait(display(fig))

    save("M_time_permalloy.png",fig)
end

# main()