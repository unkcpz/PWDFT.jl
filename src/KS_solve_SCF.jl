"""
Solves Kohn-Sham problem using traditional self-consistent field (SCF)
iterations with density mixing.
"""
function KS_solve_SCF!( Ham::Hamiltonian ;
                        startingwfc=nothing, savewfc=false,
                        betamix = 0.5, NiterMax=100, verbose=true,
                        print_final_ebands=true,
                        print_final_energies=true,
                        check_rhoe_after_mix=false,
                        use_smearing = false, kT=1e-3,
                        update_psi="LOBPCG", cheby_degree=8,
                        mix_method="simple", MIXDIM=4,
                        ETOT_CONV_THR=1e-6 )

    pw = Ham.pw
    Ngw = pw.gvecw.Ngw
    wk = Ham.pw.gvecw.kpoints.wk
    #
    kpoints = pw.gvecw.kpoints
    Nkpt = kpoints.Nkpt
    #
    Ns = pw.Ns
    Npoints = prod(Ns)
    dVol = pw.CellVolume/Npoints
    #
    electrons = Ham.electrons
    Nelectrons = electrons.Nelectrons
    Focc = copy(electrons.Focc) # make sure to use the copy
    Nstates = electrons.Nstates
    Nspin = electrons.Nspin
    #
    Nkspin = Nkpt*Nspin

    Nstates_occ = electrons.Nstates_occ

    #
    # Random guess of wave function
    #
    if startingwfc==nothing
        psiks = rand_BlochWavefunc(pw, electrons)
    else
        psiks = startingwfc
    end

    #
    # Calculated electron density from this wave function and update Hamiltonian
    #
    Rhoe = zeros(Float64,Npoints,Nspin)
    for ispin = 1:Nspin
        idxset = (Nkpt*(ispin-1)+1):(Nkpt*ispin)
        Rhoe[:,ispin] = calc_rhoe( pw, Focc[:,idxset], psiks[idxset] )
    end

    if Nspin == 2
        @printf("\nInitial integ magn_den = %18.10f\n", sum(Rhoe[:,1] - Rhoe[:,2])*dVol)
    end

    update!(Ham, Rhoe)

    Etot_old = 0.0

    Rhoe_new = zeros(Float64,Npoints,Nspin)

    diffRhoe = zeros(Nspin)

    evals = zeros(Float64,Nstates,Nkspin)

    ETHR_EVALS_LAST = 1e-6

    ethr = 0.1
    
    if mix_method == "anderson"
        df = zeros(Float64,Npoints*Nspin,MIXDIM)
        dv = zeros(Float64,Npoints*Nspin,MIXDIM)
    
    elseif mix_method in ("rpulay", "rpulay_kerker")
        XX = zeros(Float64,Npoints*Nspin,MIXDIM)
        FF = zeros(Float64,Npoints*Nspin,MIXDIM)
        x_old = zeros(Float64,Npoints*Nspin)
        f_old = zeros(Float64,Npoints*Nspin)
    end


    E_GAP_INFO = false
    Nstates_occ = electrons.Nstates_occ
    if Nstates_occ < Nstates
        E_GAP_INFO = true
        if Nspin == 2
            idx_HOMO = max(round(Int64,Nstates_occ/2),1)
            idx_LUMO = idx_HOMO + 1
        else
            idx_HOMO = Nstates_occ
            idx_LUMO = idx_HOMO + 1
        end
    end

    @printf("\n")
    @printf("Self-consistent iteration begins ...\n")
    @printf("update_psi = %s\n", update_psi)
    @printf("\n")
    @printf("mix_method = %s\n", mix_method)
    if mix_method in ("rpulay", "rpulay_kerker", "anderson")
        @printf("MIXDIM = %d\n", MIXDIM)
    end
    @printf("Density mixing with betamix = %10.5f\n", betamix)
    if use_smearing
        @printf("Smearing = %f\n", kT)
    end
    println("") # blank line before SCF iteration info

    # calculate E_NN
    Ham.energies.NN = calc_E_NN( Ham.atoms )

    CONVERGED = 0

    for iter = 1:NiterMax

        # determined convergence criteria for diagonalization
        if iter == 1
            ethr = 0.1
        elseif iter == 2
            ethr = 0.01
        else
            ethr = ethr/5.0
            ethr = max( ethr, ETHR_EVALS_LAST )
        end

        if update_psi == "LOBPCG"

            evals =
            diag_LOBPCG!( Ham, psiks, verbose=false, verbose_last=false,
                          Nstates_conv=Nstates_occ )

        elseif update_psi == "davidson"

            evals =
            diag_davidson!( Ham, psiks, verbose=false, verbose_last=false,
                            Nstates_conv=Nstates_occ )                

        elseif update_psi == "PCG"

            evals =
            diag_Emin_PCG!( Ham, psiks, verbose=false, verbose_last=false,
                            Nstates_conv=Nstates_occ )

        elseif update_psi == "CheFSI"
            # evals will be calculated later
            diag_CheFSI!( Ham, psiks, cheby_degree )

        else

            @printf("ERROR: Unknown method for update_psi = %s\n", update_psi)
            error("STOPPED")
    
        end

        if E_GAP_INFO && verbose
            println("E gap = ", minimum(evals[idx_LUMO,:] - evals[idx_HOMO,:]))
        end

        if use_smearing
            Focc, E_fermi = calc_Focc( evals, wk, Nelectrons, kT, Nspin=Nspin )
            Entropy = calc_entropy( Focc, wk, kT, Nspin=Nspin )
            Ham.electrons.Focc = copy(Focc)
        end

        for ispin = 1:Nspin
            idxset = (Nkpt*(ispin-1)+1):(Nkpt*ispin)
            Rhoe_new[:,ispin] = calc_rhoe( pw, Focc[:,idxset], psiks[idxset] )
            diffRhoe[ispin] = norm(Rhoe_new[:,ispin] - Rhoe[:,ispin])
        end

        if mix_method == "simple"
            for ispin = 1:Nspin
                Rhoe[:,ispin] = betamix*Rhoe_new[:,ispin] + (1-betamix)*Rhoe[:,ispin]
            end

        elseif mix_method == "simple_kerker"
            for ispin = 1:Nspin
                Rhoe[:,ispin] = Rhoe[:,ispin] + betamix*precKerker(pw, Rhoe_new[:,ispin] - Rhoe[:,ispin])
            end

        elseif mix_method == "rpulay"
        
            Rhoe = reshape( mix_rpulay!(
                reshape(Rhoe,(Npoints*Nspin)),
                reshape(Rhoe_new,(Npoints*Nspin)), betamix, XX, FF, iter, MIXDIM, x_old, f_old
                ), (Npoints,Nspin) )
            
            if Nspin == 2
                magn_den = Rhoe[:,1] - Rhoe[:,2]
            end

        elseif mix_method == "rpulay_kerker"
        
            Rhoe = reshape( mix_rpulay_kerker!( pw,
                reshape(Rhoe,(Npoints*Nspin)),
                reshape(Rhoe_new,(Npoints*Nspin)), betamix, XX, FF, iter, MIXDIM, x_old, f_old
                ), (Npoints,Nspin) )
            
            if Nspin == 2
                magn_den = Rhoe[:,1] - Rhoe[:,2]
            end
        
        elseif mix_method == "anderson"
            Rhoe[:,:] = mix_anderson!( Nspin, Rhoe, Rhoe_new, betamix, df, dv, iter, MIXDIM )
        
        else
            @printf("ERROR: Unknown mix_method = %s\n", mix_method)
            error("STOPPED")
        end

        for rho in Rhoe
            if rho < eps()
                rho = 0.0
            end
        end

        # renormalize
        if check_rhoe_after_mix
            integRhoe = sum(Rhoe)*dVol
            @printf("After mixing: integRhoe = %18.10f\n", integRhoe)
            Rhoe = Nelectrons/integRhoe * Rhoe
            integRhoe = sum(Rhoe)*dVol
            @printf("After renormalize Rhoe: = %18.10f\n", integRhoe)
        end

        update!( Ham, Rhoe )

        # Calculate energies
        Ham.energies = calc_energies( Ham, psiks )
        if use_smearing
            Etot = sum(Ham.energies) + Entropy
        else
            Etot = sum(Ham.energies)
        end
        diffE = abs( Etot - Etot_old )

        if verbose
            if Nspin == 1
                @printf("SCF: %8d %18.10f %18.10e %18.10e\n",
                        iter, Etot, diffE, diffRhoe[1] )
            else
                @printf("SCF: %8d %18.10f %18.10e %18.10e %18.10e\n",
                        iter, Etot, diffE, diffRhoe[1], diffRhoe[2] )
                magn_den = Rhoe[:,1] - Rhoe[:,2]
                @printf("integ magn_den = %18.10f\n", sum(magn_den)*dVol)                
            end
        
            if use_smearing
                @printf("Entropy (-TS) = %18.10f\n", Entropy)
            end
        end

        if diffE < ETOT_CONV_THR
            CONVERGED = CONVERGED + 1
        else  # reset CONVERGED
            CONVERGED = 0
        end

        if CONVERGED >= 2
            if verbose
                @printf("SCF is converged: iter: %d , diffE = %10.7e\n", iter, diffE)
            end
            break
        end
        #
        Etot_old = Etot

        flush(stdout)
    end

    # Eigenvalues are not calculated if using CheFSI.
    # We calculate them here.
    if update_psi == "CheFSI"
        for ispin = 1:Nspin
        for ik = 1:Nkpt
            Ham.ik = ik
            Ham.ispin = ispin
            ikspin = ik + (ispin - 1)*Nkpt
            Hr = psiks[ikspin]' * op_H( Ham, psiks[ikspin] )
            evals[:,ikspin] = eigvals(Hermitian(Hr))
        end
        end
    end

    Ham.electrons.ebands = evals

    if verbose && print_final_ebands
        @printf("\n")
        @printf("----------------------------\n")
        @printf("Final Kohn-Sham eigenvalues:\n")
        @printf("----------------------------\n")
        @printf("\n")
        print_ebands(Ham.electrons, Ham.pw.gvecw.kpoints)
    end

    if verbose && print_final_energies
        @printf("\n")
        @printf("-------------------------\n")
        @printf("Final Kohn-Sham energies:\n")
        @printf("-------------------------\n")
        @printf("\n")
        println(Ham.energies)
    end

    if savewfc
        for ikspin = 1:Nkpt*Nspin
            wfc_file = open("WFC_ikspin_"*string(ikspin)*".data","w")
            write( wfc_file, psiks[ikspin] )
            close( wfc_file )
        end
    end

    return

end
