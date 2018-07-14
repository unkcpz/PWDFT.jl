function alt1_KS_solve_SCF!( Ham::Hamiltonian ;
                        startingwfc=nothing,
                        β = 0.1, NiterMax=100, verbose=false,
                        check_rhoe_after_mix=true,
                        update_psi="LOBPCG", cheby_degree=8,
                        ETOT_CONV_THR=1e-6 )
    
    @assert( Ham.pw.gvecw.kpoints.Nkpt == 1 )
    @assert( Ham.electrons.Nspin == 1 )

    pw = Ham.pw
    Ngw = pw.gvecw.Ngw
    Ngwx = pw.gvecw.Ngwx
    Ns = pw.Ns
    Npoints = prod(Ns)
    dVol = pw.Ω/Npoints
    electrons = Ham.electrons
    Nelectrons = electrons.Nelectrons
    Focc = electrons.Focc
    Nstates = electrons.Nstates
    Nstates_occ = electrons.Nstates_occ

    #
    # Random guess of wave function
    #
    if startingwfc==nothing
        srand(1234)
        psi = ortho_sqrt( rand(ComplexF64,Ngwx,Nstates) )
    else
        psi = startingwfc
    end

    # Calculate electron density from this wave function and update Hamiltonian
    Rhoe = calc_rhoe( Ham, psi )
    update!(Ham, Rhoe)

    Etot_old = 0.0

    Rhoe_new = zeros(Float64,Npoints)

    evals = zeros(Float64,Nstates)

    ETHR_EVALS_LAST = 1e-6

    ethr = 0.1

    MIXDIM = 4
    XX = zeros(Float64,Npoints,MIXDIM)
    FF = zeros(Float64,Npoints,MIXDIM)

    @printf("\n")
    @printf("Self-consistent iteration begins ...\n")
    @printf("\n")
    @printf("Density mixing with β = %10.5f\n", β)
    @printf("\n")

    CONVERGED = 0

    for iter = 1:40

        if update_psi == "LOBPCG"
            evals, psi =
            diag_lobpcg( Ham, psi, verbose=false, verbose_last=false,
                             Nstates_conv = Nstates_occ )

        elseif update_psi == "PCG"
            
            # determined convergence criteria for diagonalization
            if iter == 1
                ethr = 0.1
            elseif iter == 2
                ethr = 0.01
            else
                ethr = ethr/5.0
                ethr = max( ethr, ETHR_EVALS_LAST )
            end

            evals, psi =
            diag_Emin_PCG( Ham, psi, TOL_EBANDS=ethr, verbose=false )

        elseif update_psi == "CheFSI"
            
            ub, lb = get_ub_lb_lanczos( Ham, Nstates*2 )
            psi = chebyfilt( Ham, psi, cheby_degree, lb, ub)
            psi = ortho_gram_schmidt( psi )

        else

            @printf("ERROR: Unknown method for update_psi = %s\n", update_psi)
            exit()
        end

        Rhoe_new = calc_rhoe( Ham, psi )
        
        #Rhoe[:] = β*Rhoe_new + (1-β)*Rhoe
        
        #Rhoe[:,:] = mix_anderson!( Nspin, Rhoe, Rhoe_new, β, df, dv, iter, MIXDIM )
        Rhoe = mix_rpulay!( Rhoe, Rhoe_new, β, XX, FF, iter, MIXDIM )

        for rho in Rhoe
            if rho < eps()
                rho = 0.0
            end
        end

        if check_rhoe_after_mix
            integRhoe = sum(Rhoe)*dVol
            @printf("After mixing: integRhoe = %18.10f\n", integRhoe)
            Rhoe = Nelectrons/integRhoe * Rhoe
            integRhoe = sum(Rhoe)*dVol
            @printf("After renormalize Rhoe: = %18.10f\n", integRhoe)
        end

        update!( Ham, Rhoe )

        # Calculate energies
        Ham.energies = calc_energies( Ham, psi )
        Etot = Ham.energies.Total
        diffE = abs( Etot - Etot_old )

        @printf("SCF: %8d %18.10f %18.10e\n", iter, Etot, diffE )

        if diffE < ETOT_CONV_THR
            CONVERGED = CONVERGED + 1
        else  # reset CONVERGED
            CONVERGED = 0
        end

        if CONVERGED >= 2
            @printf("SCF is converged: iter: %d , diffE = %10.7e\n", iter, diffE)
            break
        end

        #
        Etot_old = Etot
    end

    # Eigenvalues are not calculated if using CheFSI.
    # We calculate them here.
    if update_psi == "CheFSI"
        Hr = psi' * op_H( Ham, psi )
        evals = real(eigvals(Hr))
    end

    Ham.electrons.ebands[:,1] = evals

    return

end