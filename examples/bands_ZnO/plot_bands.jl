using DelimitedFiles
using DelimitedFiles
using Printf
using LaTeXStrings
using PGFPlotsX
using PWDFT: Ry2eV

function read_special_kpts( filebands::String )
    f = open(filebands, "r")
    l = readline(f)
    Nkpt_spec = parse( Int64, replace(l, "#" => "") )
    symb_kpts_spec = Array{String}(undef,Nkpt_spec)
    x_kpts_spec = zeros(Nkpt_spec)
    for ik = 1:Nkpt_spec
        l = readline(f)
        ll = split( strip(replace(l, "#" => "")) , " " )
        x_kpts_spec[ik] = parse( Float64, ll[1] )
        symb_kpts_spec[ik] = ll[2]
        if (symb_kpts_spec[ik] == "G") || (symb_kpts_spec[ik] == "G1")
            symb_kpts_spec[ik] = L"$\Gamma$"
        end
    end
    close(f)
    println(symb_kpts_spec)

    return symb_kpts_spec, x_kpts_spec
end

function test_plot_bands()

    filebands = "TEMP_bands.dat"

    symb_kpts_spec, x_kpts_spec = read_special_kpts(filebands)

    ebands = readdlm(filebands, comments=true)
    Nbands = size(ebands)[2] - 1
    #Nbands = 5
    kcart = ebands[:,1]

    E_f = maximum(ebands[:,18])
    
    plt_inc = Array{Plot,1}(undef,Nbands)
    for iband = 1:Nbands
        plt_inc[iband] = @pgf PlotInc( {
            "solid",
            mark = "*",
            color = "black",
            mark_options = "fill=cyan",
            mark_size = "1pt",
        }, Coordinates(kcart, (ebands[:,iband+1] .- E_f)*2*Ry2eV ) )
    end

    fig = @pgf Axis( {
             height = "10cm",
             width = "8cm",
             xtick = x_kpts_spec,
             xticklabels = symb_kpts_spec,
             ymin = -8.0,
             ymax = 8.0,
             xmin = 0.0,
             xmax = maximum(kcart),
             "xmajorgrids",
             "ymajorgrids",
          },
          plt_inc...)
    pgfsave("TEMP_bands.tex", fig)
    pgfsave("TEMP_bands.pdf", fig)

end

test_plot_bands()

