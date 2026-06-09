using LinearAlgebra
using Statistics

using AstroImages

using MAT
matvars = matread("/opt/VENOMS/NewEarthLab/config/BAX307-Z2C.mat")
z2c = matvars["Z2C"]
actuator_map = BitMatrix(load("/mnt/datadrive/DATA/dm/BAX307-actu-map.fits"))



## testing
# actumap = Bool.(matread("/opt/VENOMS/NewEarthLab/config/BAX307-actu-map.mat")["actus"])

# viz = zeros(size(actumap))
# viz[actumap] .= z2c[3,:]
# imview(viz)

# N_modes * N_act
amps = fill(0.2, size(z2c,1))
modemat = amps .* z2c
# modemat = modemat[1:7,:] # Which zernikes do we want? All in this case.
# modemat = modemat[1:5,:] # Which zernikes do we want? All in this case.

# Make outer ring all zero
x, y = axes(actuator_map)
x = x .- mean(x)
y = y .- mean(y)
r = sqrt.(x.^2 .+y'.^2)
outer_ring = (r .>= 11).&& actuator_map
outer_ring_vec = vec(map(findall(actuator_map)) do I
    I ∈ findall(outer_ring)
end)
modemat[:,outer_ring_vec].=0

actuator_mask_all= Bool.(load("/mnt/datadrive/DATA/SCC/actuator_mask.fits"))
actuator_mask = actuator_mask_all[actuator_map]

modemat = mapslices(modemat, dims=2) do cmd
    cmd[.!actuator_mask] .= 0
    cmd[actuator_mask] .- mean(cmd[actuator_mask])
    cmd
end

# Project out high order fourier modes
modemat_fourier, cyc_xs, cyc_ys, phases = load("/mnt/datadrive/DATA/SCC/modemat-all.fits", :)

# # Pick what fourier modes (in cycles/pupil) we should project out.
# # Modes with this radius or above will bre removed from the zernike basis to prevent fighting.
# mode_inn_cutoff = 5.5

# ##
cyc_rs = sqrt.(cyc_xs.^2 .+ cyc_ys.^2)
# modes_to_remove_ii = findall(
#     # cyc_rs .>= mode_inn_cutoff
#     # 4 .<= cyc_rs .<= 5.5#,#mode_inn_cutoff
#     # 5 .<= cyc_rs #.<= 8#,#mode_inn_cutoff
#     7 .<= cyc_rs #.<= 8#,#mode_inn_cutoff
# )

# modes_to_remove = collect(modemat_fourier[modes_to_remove_ii,:])

# ## Testing
# plot(; xlabel="SCC modes (cycles per pupil)", framestyle=:box, ylabel="dot product")
# scatter!(cyc_rs[ii], modemat_fourier[ii,:]' \ modemat[3,:], label="tilt")
# scatter!(cyc_rs[ii], modemat_fourier[ii,:]' \ modemat[20,:], label="zern #20")


# ##
# actm = AstroImage(zeros(size(actuator_map)))
# actm[actuator_map] .= modes_to_remove[1,:]
# actm
# ##
# actm = AstroImage(zeros(size(actuator_map)))
# actm[actuator_map] .= modemat[1,:]
# actm
# ##
# # c = modemat * modes_to_remove'
# modematclean = mapslices(modemat[1:end,:], dims=2) do zernmode
#     c =  modes_to_remove' \ zernmode
#     @show c
#     (zernmode' - c'*modes_to_remove)'
#     # (zernmode' + c'*modes_to_remove)'
# end
# # modematclean = [modemat[1:2,:]; modematclean]
# modematclean = mapslices(modematclean, dims=2) do cmd
#     cmd[actuator_mask] .-= mean(cmd[actuator_mask])
#     cmd
# end

# ##
# actm = AstroImage(zeros(size(actuator_map)))
# actm[actuator_map] .= modematclean[1,:]
# actm
# ##

modematclean = [modemat[1:2,:]; modemat_fourier[cyc_rs .< 2,:]]

rmsnm = mapslices(modematclean,dims=2) do actuator_volts
    actuator_nm = actuator_volts .* 10 .* 1e3
    sqrt(mean(px^2 for px in vec(actuator_nm)))
end
modematclean ./= rmsnm
modematclean .*= 25 #nm rms
modematclean = Float32.(modematclean)


# TODO: I should project Tip and Tilt out of the fourier mode basis

save("/mnt/datadrive/DATA/LOWFS/modes-to-actus.fits", modematclean)
@show size(modematclean)

##
save("/mnt/datadrive/DATA/LOWFS/actus-to-modes.fits", pinv(modematclean))



