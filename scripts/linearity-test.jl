using Printf
function measure_response_matrix(
    camera,
    dm,
    modemat,
    N_frame_wait=2
)
    img = capture(camera)
    intermat = zeros(size(img)...,size(modemat)[2:3]...)
    # TODO: once we have multiple channels we can just put 0 instead
    # of restoring previous command
    offset = collect(getact(dm))
    for i_mode in axes(modemat,3)
        # Big jump in DM shape; wait while vibrations settle down
        setact!(dm, offset .+ 0.2modemat[:,1,i_mode])
        sleep(0.005)
        setact!(dm, offset .+ 0.4modemat[:,1,i_mode])
        sleep(0.005)
        setact!(dm, offset .+ 0.6modemat[:,1,i_mode])
        sleep(0.005)
        setact!(dm, offset .+ 0.8modemat[:,1,i_mode])
        sleep(0.005)
        setact!(dm, offset .+    modemat[:,1,i_mode])
        sleep(0.015)
        for i_amp in axes(modemat,2)
            setact!(dm, offset .+ @view modemat[:,i_amp,i_mode])
            # Skip frames to wait for DM to settle
            for i_wait in 1:N_frame_wait
                capture!(img,camera)
            end
            capture!(img,camera)
            intermat[:,:,i_amp,i_mode] = img./sum(img)
            # note: we are dividing by the total flux to normalize out source intensity variations
        end
        setact!(dm, offset .+ 0.8modemat[:,1,i_mode])
        sleep(0.005)
        setact!(dm, offset .+ 0.6modemat[:,1,i_mode])
        sleep(0.005)
        setact!(dm, offset .+ 0.4modemat[:,1,i_mode])
        sleep(0.005)
        setact!(dm, offset .+ 0.2modemat[:,1,i_mode])
        sleep(0.005)
        setact!(dm, offset)
        sleep(0.005)
    end
    setact!(dm, offset)
    setact!(dm, offset)
    capture!(img,camera)

    return intermat
end

using MAT
using AstroImages
using LinearAlgebra

camera = connectdevice("GoldEye")
dm = connectdevice("ALPAO468")

matvars = matread("/opt/VENOMS/NewEarthLab/config/BAX307-Z2C.mat")
z2c = matvars["Z2C"]

# # testing
# actumap = Bool.(matread("/opt/VENOMS/NewEarthLab/config/BAX307-actu-map.mat")["actus"])

# viz = zeros(size(actumap))
# viz[actumap] .= z2c[3,:]
# imview(viz)

# N_modes * N_act
# modemat = 0.15 .* z2c[1:3,:]

# Scale down the command strength we test with by mode #
mode_amplitudes_scales = [1.0, 1.0, range(start=1.0,stop=0.1, length=size(z2c,1)-2)...]
z2c_scaled = z2c .* mode_amplitudes_scales

amplitudes = -0.2:0.01:0.2
modemat = stack(
    amplitude .* z2c_scaled[i,:]
    for amplitude in amplitudes, i in axes(z2c,1)
    # for amplitude in -0.4:0.01:0.4, i in axes(z2c,1)[1:5]
)



# Capture "interaction" matrix
# N_X_pix * N_Y_pix
t = Threads.@spawn measure_response_matrix(
    camera,
    dm,
    modemat,
)
linearity_mat = fetch(t)

imview(linearity_mat)

##
response_curves = mapslices(linearity_mat,dims=(1,2)) do img

    # Subtract the reference image
    i = img[image_mask]
    i .-= view(reference_image,image_mask)

    # Use interaction matrix to determine the linear response of the sensor
    # i.e. pixels -> modes
    modal_coefficients =  image_to_modes' * i

    # # Now convert this modal basis into actuator strokes.
    # # Note: these are linear operations so could be folded together, but 
    # # it is faster to do it in two steps since the number of controlled
    # # modes is small compared to the number of pixels or actuators.
    # actus_coefficients = state.modes_to_actus' * state.modal_coefficients

    # # Publish our measurement in actuator space
    # vec(pub_data) .= state.actus_coefficients

end
response_curves = reshape(response_curves, size(response_curves,1), size(response_curves)[3:4]...)

# Linearity Plots
# fname = "/mnt/datadrive/DATA/2023-07-20/5zernikes-rand-linearity-results-0.1amp-"
fname = "/mnt/datadrive/DATA/2023-07-20/5zernikes-linearity-results-0.1amp-"
for i_target = axes(response_curves,1)
    ii_considered = axes(response_curves,1)
    plot(
        framestyle=:box,
        title="Mode $i_target",
        xlims=:symmetric,
        ylims=:symmetric,
    )
    a = mode_amplitudes_scales' .* amplitudes
    plot!(
        a[:,setdiff(ii_considered,i_target)],
        response_curves[i_target,:,setdiff(ii_considered,i_target)],
        label=string.(ii_considered'),
        alpha=0.4
    )
    plot!(
        a[:,i_target],
        response_curves[i_target,:,i_target], color=:black,lw=2.5, label=string(i_target)
    )
    plot!([minimum(a),maximum(a)],[minimum(a),maximum(a)],color=:red,lw=1)
    savefig(fname*@sprintf("mode-%03d.png",i_target))
end
##
# # Same differential imaged for visualizing etc.
# save("/mnt/datadrive/DATA/LOWFS/linearity-scan-images.fits",response_mat)

# # Use a threshold to find a region of interest where there is some
# # actual response by the LOWFS.
# # Take the maximum absolute value across all modes and ignore pixels
# # that never respond more than 0.1% of the pixel with the highest response.
# max_response_per_px = maximum(abs.(response_mat),dims=3)[:,:]
# image_mask = max_response_per_px .> 0.01maximum(max_response_per_px)

# # Note: this scheme has not been heavily tested vs tradeoffs etc, just seemed like a good idea (WT.)
# save("/mnt/datadrive/DATA/LOWFS/image-mask.fits",UInt8.(image_mask))


# # Capture a reference image. This can be updated separately from the main calibration
# reference_image = capture(camera)

# # Divide response matrix by the total intensity of the reference image
# # This prevents a flux-dependent signal
# reference_image ./= sum(reference_image)
# save("/mnt/datadrive/DATA/LOWFS/reference-image.fits", reference_image)

# # N_X_pix * N_Y_pix * modes -> N_pix * modes
# flattened_images = response_mat[image_mask,:]

# # TODO: might need svd / Tiknohov regularisation
# interaction_mat  = pinv(flattened_images)

# # Now calculate interaction matrix (regularized inverse)
# save("/mnt/datadrive/DATA/LOWFS/image-to-modes.fits", collect(transpose(interaction_mat)))
