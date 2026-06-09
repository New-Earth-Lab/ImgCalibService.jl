function cog(img)
    tot = sum(img)
    X = sum(img .* axes(img,1))/tot
    Y = sum(img .* axes(img,2)')/tot
    return X, Y
end

function measure_response_matrix(
    camera,
    dm,
    modemat,
    coadds=150,
    N_frame_wait=10,
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

function measure_response_matrix_cog(
    camera,
    dm,
    modemat,
    dark;
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
    integ = zeros(eltype(img),size(img))
    intermat_cog = zeros(2,2)

    # TODO: once we have multiple channels we won't need offset 
    # for restoring the previous command
    offset = getact(dm)

    # If we are on a tip/tilt mode, record the centre of gravity coordinates into the top left pixels as intensities.

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
        integ .= 0
        for i_coadd in 1:coadds
            capture!(img, camera)
            # Skip frames to wait for DM to settle
            for i_wait in 1:N_frame_wait
                capture!(img,camera)
            end
            capture!(img,camera)
            integ .+= img
        end
        i = sum(integ.-dark*coadds,dims=3)[:,:]
        X, Y = cog(i.*cog_image_mask)
        @show X Y
        intermat_cog[1,i_mode] += X
        intermat_cog[2,i_mode] += Y
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
        integ .= 0
        for i_coadd in 1:coadds
            capture!(img, camera)
            # Skip frames to wait for DM to settle
            for i_wait in 1:N_frame_wait
                capture!(img,camera)
            end
            capture!(img,camera)
            integ .+= img
        end
        i = sum(integ.-dark*coadds,dims=3)[:,:]
        X, Y = cog(i.*cog_image_mask)
        @show X Y
        intermat_cog[1,i_mode] -= X
        intermat_cog[2,i_mode] -= Y
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
    return intermat_cog
end

using MAT
using AstroImages
using LinearAlgebra
using Statistics
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
amps = fill(0.1, size(z2c,1))
modemat = amps .* z2c
# modemat = modemat[1:5,:] # Which zernikes do we want? All in this case.
modemat = modemat[1:2,:] # Which zernikes do we want? All in this case.

# Make outer ring all zero
x, y = axes(dm.actuator_map)
x = x .- mean(x)
y = y .- mean(y)
r = sqrt.(x.^2 .+y'.^2)
outer_ring = (r .>= 11).&& dm.actuator_map
outer_ring_vec = vec(map(findall(dm.actuator_map)) do I
    I ∈ findall(outer_ring)
end)
modemat[:,outer_ring_vec].=0


save("/mnt/datadrive/DATA/LOWFS/modes-to-actus.fits", modemat)


# Load the camera dark
dark = collect(load("/mnt/datadrive/DATA/LOWFS/dark.fits"))

# Capture a reference image. This can be updated separately from the main calibration
reference_image = median(stack([
    capture(camera)
    for _ in 1:30
]),dims=3)[:,:]

# Divide response matrix by the total intensity of the reference image
# This prevents a flux-dependent signal
reference_image ./= sum(reference_image)
save("/mnt/datadrive/DATA/LOWFS/reference-image.fits", reference_image)

# Fill in COG pixels and mask
cog_image_mask = falses(size(reference_image))
cog_image_mask[15 .< axes(reference_image,1) .< size(reference_image,1)/2,:] .= true

X, Y = cog(reference_image.*cog_image_mask)

save("/mnt/datadrive/DATA/LOWFS/cog-image-mask.fits",UInt8.(cog_image_mask))
# save("/mnt/datadrive/DATA/LOWFS/cog-reference.fits",[X,Y])
save("/mnt/datadrive/DATA/LOWFS/cog-reference.fits",[Y,X])



t = Threads.@spawn measure_response_matrix_cog(
    camera,
    dm,
    modemat[1:2,:],
    dark
)
response_mat_cog = fetch(t)

# Capture interaction matrix (it's differential so no ref. image needed)
# N_X_pix * N_Y_pix
t = Threads.@spawn measure_response_matrix(
    camera,
    dm,
    modemat,
)
response_mat = fetch(t)

# Same differential imaged for visualizing etc.
save("/mnt/datadrive/DATA/LOWFS/differential-response-images.fits",response_mat)
LabSoftware.imview(response_mat)

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

# svd_modes = 3

# out     = svd(flattened_images)
# S       = copy(out.S)
# S_trunc = copy(out.S)
# # regu        = "No Regularisation"   

# # Apply SVD cutoff
# # if regu == "Truncation"
# #     S_trunc[svd_modes:end] .= 0
# #     A_cut = out.U * Diagonal(S_trunc) * out.Vt
# # elseif regu == "Tiknohov"
#     S_trunc = (S .^2 .+ S[svd_modes] ^ 2) ./ S 
#     A_cut = out.U * Diagonal(S_trunc) * out.Vt
# # elseif regu == "No Regularisation"
#     # A_cut = out.U * Diagonal(out.S) * out.Vt
# # end 
# interaction_mat  = pinv(A_cut)


interaction_mat_cog  = inv(response_mat_cog)

# Now calculate interaction matrix (regularized inverse)
image_to_modes = collect(transpose(interaction_mat))
slopes_to_TT = collect(transpose(interaction_mat_cog))
save("/mnt/datadrive/DATA/LOWFS/image-to-modes.fits", image_to_modes)
save("/mnt/datadrive/DATA/LOWFS/slopes-to-TT.fits", slopes_to_TT)