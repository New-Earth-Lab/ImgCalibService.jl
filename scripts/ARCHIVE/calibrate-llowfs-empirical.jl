function measure_response_matrix(
    camera,
    dm,
    modemat,
    coadds=50,
    N_frame_wait=2,
    t_ministep=0.0002
)
    # Speedy busy sleep.
    function minisleep(t)
        stop_time = time() + t
        while time() < stop_time
        end
    end
    img = capture(camera)
    intermat = zeros(size(img)...,size(modemat,1), coadds)
    # TODO: once we have multiple channels we can just put 0 instead
    # of restoring previous command
    offset = getact(dm)
    # Note: we go through all modes one co add at  a time. 
    # The hope is this prevents any drift during measurements ending up all in one mode
    for (i_mode, mode) in enumerate(eachrow(modemat))
        setact!(dm, offset .+ 0.2mode)
        minisleep(t_ministep)
        setact!(dm, offset .+ 0.4mode)
        minisleep(t_ministep)
        setact!(dm, offset .+ 0.6mode)
        minisleep(t_ministep)
        setact!(dm, offset .+ 0.8mode)
        minisleep(t_ministep)
        setact!(dm, offset .+    mode)
        minisleep(0.015)
        for i_coadd in 1:coadds
            capture!(img, camera)
            # Skip frames to wait for DM to settle
            for i_wait in 1:N_frame_wait
                capture!(img,camera)
            end
            capture!(img,camera)
            intermat[:,:,i_mode,i_coadd] += img./sum(img)
        end
        setact!(dm, offset .+ 0.8mode)
        minisleep(t_ministep)
        setact!(dm, offset .+ 0.6mode)
        minisleep(t_ministep)
        setact!(dm, offset .+ 0.4mode)
        minisleep(t_ministep)
        setact!(dm, offset .+ 0.2mode)
        minisleep(t_ministep)
        setact!(dm, offset)
        minisleep(t_ministep)
        setact!(dm, offset .- 0.2mode)
        minisleep(t_ministep)
        setact!(dm, offset .- 0.4mode)
        minisleep(t_ministep)
        setact!(dm, offset .- 0.6mode)
        minisleep(t_ministep)
        setact!(dm, offset .- 0.8mode)
        minisleep(t_ministep)
        setact!(dm, offset .-    mode)
        minisleep(0.015)
        for i_coadd in 1:coadds
            # Skip frames to wait for DM to settle
            for i_wait in 1:N_frame_wait
                capture!(img,camera)
            end
            capture!(img,camera)
            intermat[:,:,i_mode,i_coadd] -= img./sum(img)
            # note: we are dividing by the total flux to normalize out source intensity variations
        end
        setact!(dm, offset .- 0.8mode)
        minisleep(t_ministep)
        setact!(dm, offset .- 0.6mode)
        minisleep(t_ministep)
        setact!(dm, offset .- 0.4mode)
        minisleep(t_ministep)
        setact!(dm, offset .- 0.2mode)
        minisleep(t_ministep)
        setact!(dm, offset)
        minisleep(t_ministep)
    end
    setact!(dm, offset)
    intermat = @views median(intermat,dims=4)[:,:,:]
    intermat .= intermat ./ 2

    return intermat
end

using MAT
using AstroImages
using LinearAlgebra
using Statistics

camera = connectdevice("GoldEye")
dm = connectdevice("ALPAO468")

modemat = 0.1 .* collect(load("/mnt/datadrive/DATA/LOWFS/empirical-mode-identification-dm-modes.fits")[:,1:5]')

save("/mnt/datadrive/DATA/LOWFS/modes-to-actus.fits", modemat)


# Capture a reference image. This can be updated separately from the main calibration
reference_image = median(stack([
    capture(camera)
    for _ in 1:30
]),dims=3)[:,:]

# Divide response matrix by the total intensity of the reference image
# This prevents a flux-dependent signal
reference_image ./= sum(reference_image)
save("/mnt/datadrive/DATA/LOWFS/reference-image.fits", reference_image)

# Capture interaction matrix (it's differential so no ref. image needed)
# N_X_pix * N_Y_pix
t = Threads.@spawn measure_response_matrix(
    camera,
    dm,
    modemat,
)
response_mat = fetch(t)

@info "recorded response matrix"
# Same differential imaged for visualizing etc.
save("/mnt/datadrive/DATA/LOWFS/differential-response-images.fits",response_mat)

# Use a threshold to find a region of interest where there is some
# actual response by the LOWFS.
# Take the maximum absolute value across all modes and ignore pixels
# that never respond more than 0.1% of the pixel with the highest response.
max_response_per_px = maximum(abs.(response_mat),dims=3)[:,:]
image_mask = max_response_per_px .> 0.04maximum(max_response_per_px)

# Note: this scheme has not been heavily tested vs tradeoffs etc, just seemed like a good idea (WT.)
save("/mnt/datadrive/DATA/LOWFS/image-mask.fits",UInt8.(image_mask))


# N_X_pix * N_Y_pix * modes -> N_pix * modes
flattened_images = response_mat[image_mask,:]

# TODO: might need svd / Tiknohov regularisation
interaction_mat  = pinv(flattened_images)

# Now calculate interaction matrix (regularized inverse)
save("/mnt/datadrive/DATA/LOWFS/image-to-modes.fits", collect(transpose(interaction_mat)))