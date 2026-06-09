using Aeron
# include("/opt/spiders/lowfsservice/src/wire-format.jl")
using SpidersMessageEncoding
# OUTPUT DM COMMANDS (preparation)
output_conf = AeronConfig(
    channel="aeron:ipc",
    stream=1005,
)


# Speedy busy sleep.
function minisleep(t)
    stop_time = time() + t
    while time() < stop_time
    end
end

# This is a byte buffer where we store our messages we want to send over Aeron
# We can view into it to see the last command we sent.
buffer = zeros(UInt8, 468*8+60*4)

# This header holds the buffer along with metadata to send over the wire
# const pubhead = VenomsImageMessage(buffer)
# SizeX!(pubhead, 468)
# SizeY!(pubhead, 1)
# Format!(pubhead, 10) # Float64
# MetadataLength!(pubhead,  0)
# ImageBufferLength!(pubhead, 468*8)
# ImageBufferLength(pubhead)

const pubhead = ArrayMessage{Float32,1}(buffer)
arraydata!(pubhead, zeros(Float32, 468))


aeronpub = Aeron.publisher(output_conf)
function setact!(aeronpub, command_vec::AbstractVector{<:Number})
    for v in command_vec
        if !(-0.5 < v < 0.5)
            error("Provided DM command exceeds valid range (-0.5 < cmd < 0.5)")
        end
    end
    current_time = round(UInt64, time()*1e9) # TODO: this is messy. Unclear if the accuarcy is good.
    pubhead.header.TimestampNs = current_time
    vec(Image(pubhead)) .= vec(command_vec)
    sleep(0.01)
    status = Aeron.publication_offer(aeronpub, pubhead.buffer)
    if status != :success
        @warn "Did not succeed in sending command"
    end
end

## Receive Images

input_conf = AeronConfig(
    channel="aeron:ipc",
    stream=1013,
)

# storage = Ref{Matrix{Float32}}(zeros(Float32,0,0))
# function spincapture(storage,aeronsub)
#     for frame in aeronsub
#         header = VenomsImageMessage(frame.buffer)
#         storage[] = Image(header)
#     end
# end
# errormonitor(Threads.@spawn spincapture(storage,aeronsub))
# ##
# function capture!(out, aeronsub)
#     sleep(2/850)
#     out .= storage[]
# end
# function capture(aeronsub)
#     sleep(2/850)
#     return collect(storage[])
# end

##

function cog(img)
    tot = sum(img)
    X = sum(img .* axes(img,1))/tot
    Y = sum(img .* axes(img,2)')/tot
    return X, Y
end

function measure_response_matrix(
    input_conf,
    dm,
    modemat,
    coadds=150,
    N_frame_wait=2,
    t_ministep=0.0002
)
    return Aeron.subscribe(input_conf) do aeronsub
        frame, _ = iterate(aeronsub)
        header = VenomsImageMessage(frame.buffer)
        img = Image(header)


        # Spin to discard old images cached in the term buffer
        while round(UInt64, time()*1e9) - TimestampNs(header) > 1e-3*1e9
            frame, _ = iterate(aeronsub)
            header = VenomsImageMessage(frame.buffer)
            @info "discarding stale frame"
        end
        
        intermat = zeros(size(img)...,size(modemat,1), coadds)
        # TODO: once we have multiple channels we can just put 0 instead
        # of restoring previous command
        offset = zeros(468)
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
                frame, _ = iterate(aeronsub)
                # Skip frames to wait for DM to settle
                for i_wait in 1:N_frame_wait
                    frame, _ = iterate(aeronsub)
                end
                frame, _ = iterate(aeronsub)
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
                    frame, _ = iterate(aeronsub)
                end
                frame, _ = iterate(aeronsub)
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
end

function measure_response_matrix_cog(
    input_conf,
    dm,
    modemat,
    coadds=50,
    N_frame_wait=2,
    t_ministep=0.0002
)
    return Aeron.subscribe(input_conf) do aeronsub
        frame, _ = iterate(aeronsub)
        header = VenomsImageMessage(frame.buffer)
        img = Image(header)

        # Spin to discard old images cached in the term buffer
        while round(UInt64, time()*1e9) - TimestampNs(header) > 1e-3*1e9
            frame, _ = iterate(aeronsub)
            header = VenomsImageMessage(frame.buffer)
            @info "discarding stale frame"
        end

        frame, _ = iterate(aeronsub)
        integ = zeros(eltype(img),size(img))
        intermat_cog = zeros(2,2)

        # TODO: once we have multiple channels we won't need offset 
        # for restoring the previous command
        offset = zeros(468)

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
                frame, _ = iterate(aeronsub)
                # Skip frames to wait for DM to settle
                for i_wait in 1:N_frame_wait
                    frame, _ = iterate(aeronsub)
                end
                frame, _ = iterate(aeronsub)
                integ .+= img
            end
            i = sum(integ,dims=3)[:,:]
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
                frame, _ = iterate(aeronsub)
                # Skip frames to wait for DM to settle
                for i_wait in 1:N_frame_wait
                    frame, _ = iterate(aeronsub)
                end
                    frame, _ = iterate(aeronsub)
                integ .+= img
            end
            i = sum(integ,dims=3)[:,:]
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
        @show setact!(dm, offset)
        return intermat_cog
    end
end

using MAT
using AstroImages
using LinearAlgebra
using Statistics
dm = aeronpub

matvars = matread("/opt/VENOMS/NewEarthLab/config/BAX307-Z2C.mat")
actuator_map = BitMatrix(load("/mnt/datadrive/DATA/dm/BAX307-actu-map.fits"))
z2c = matvars["Z2C"]

## testing
# actumap = Bool.(matread("/opt/VENOMS/NewEarthLab/config/BAX307-actu-map.mat")["actus"])

# viz = zeros(size(actumap))
# viz[actumap] .= z2c[3,:]
# imview(viz)

# # N_modes * N_act
# amps = fill(0.1, size(z2c,1))
# modemat = amps .* z2c
# modemat = modemat[1:10,:] # Which zernikes do we want? All in this case.
# # modemat = modemat[1:2,:] # Which zernikes do we want? All in this case.

# # Make outer ring all zero
# x, y = axes(actuator_map)
# x = x .- mean(x)
# y = y .- mean(y)
# r = sqrt.(x.^2 .+y'.^2)
# outer_ring = (r .>= 11).&& actuator_map
# outer_ring_vec = vec(map(findall(actuator_map)) do I
#     I ∈ findall(outer_ring)
# end)
# modemat[:,outer_ring_vec].=0


modemat = load("/mnt/datadrive/DATA/LOWFS/modes-to-actus.fits")

# Capture a reference image. This can be updated separately from the main calibration
# reference_image = median(stack([
#     capture(camera)
#     for _ in 1:30
# ]),dims=3)[:,:]

##

reference_image = Aeron.subscribe(input_conf) do aeronsub

    # Spin to discard old images cached in the term buffer
    frame, _ = iterate(aeronsub)
    header = VenomsImageMessage(frame.buffer)
    while round(UInt64, time()*1e9) - TimestampNs(header) > 1e-3*1e9
        frame, _ = iterate(aeronsub)
        header = VenomsImageMessage(frame.buffer)
        @info "discarding stale frame"
    end

    # Grab 30 frames and average them
    frames = map(zip(aeronsub, 1:30)) do  (frame, i_frame)
        header = VenomsImageMessage(frame.buffer)
        img = Image(header)
        return collect(img)
    end
    return median(stack(frames),dims=3)[:,:]
end

# Divide response matrix by the total intensity of the reference image
# This prevents a flux-dependent signal
reference_image ./= sum(reference_image)
save("/mnt/datadrive/DATA/LOWFS/reference-image.fits", reference_image)

# Fill in COG pixels and mask
cog_image_mask = falses(size(reference_image))
cog_image_mask[70 .< axes(reference_image,1) .< 102,:] .= true

Xx, Yy = cog(reference_image.*cog_image_mask)

save("/mnt/datadrive/DATA/LOWFS/cog-image-mask.fits",UInt8.(cog_image_mask))
# save("/mnt/datadrive/DATA/LOWFS/cog-reference.fits",[X,Y])
save("/mnt/datadrive/DATA/LOWFS/cog-reference.fits",[Xx,Yy])

##

response_mat_cog = measure_response_matrix_cog(
    input_conf,
    dm,
    1.5 .* modemat[1:2,:],
)
response_mat_cog ./= 1.5

## Capture interaction matrix (it's differential so no ref. image needed)
# N_X_pix * N_Y_pix
response_mat = measure_response_matrix(
    input_conf,
    dm,
    modemat,
)

##
# Same differential imaged for visualizing etc.
save("/mnt/datadrive/DATA/LOWFS/differential-response-images.fits",response_mat)

# Use a threshold to find a region of interest where there is some
# actual response by the LOWFS.
# Take the maximum absolute value across all modes and ignore pixels
# that never respond more than 0.1% of the pixel with the highest response.
max_response_per_px = maximum(abs.(response_mat),dims=3)[:,:]
image_mask = max_response_per_px .> 0.04maximum(max_response_per_px)

# Only look at the blob
image_mask .&= cog_image_mask

# Note: this scheme has not been heavily tested vs tradeoffs etc, just seemed like a good idea (WT.)
save("/mnt/datadrive/DATA/LOWFS/image-mask.fits",UInt8.(image_mask))


# N_X_pix * N_Y_pix * modes -> N_pix * modes
flattened_images = response_mat[image_mask,:]

# TODO: might need svd / Tiknohov regularisation
# interaction_mat  = pinv(flattened_images)

svd_modes = 5

out     = svd(flattened_images)
S       = copy(out.S)
S_trunc = copy(out.S)
# regu        = "No Regularisation"   

# Apply SVD cutoff
# if regu == "Truncation"
#     S_trunc[svd_modes:end] .= 0
#     A_cut = out.U * Diagonal(S_trunc) * out.Vt
# elseif regu == "Tiknohov"
    S_trunc = (S .^2 .+ S[svd_modes] ^ 2) ./ S 
    A_cut = out.U * Diagonal(S_trunc) * out.Vt
# elseif regu == "No Regularisation"
    # A_cut = out.U * Diagonal(out.S) * out.Vt
# end 
interaction_mat  = pinv(A_cut)


interaction_mat_cog  = inv(response_mat_cog)

##
# Now calculate interaction matrix (regularized inverse)
image_to_modes = collect(transpose(interaction_mat))
slopes_to_TT = collect(transpose(interaction_mat_cog))
save("/mnt/datadrive/DATA/LOWFS/image-to-modes.fits", image_to_modes)
save("/mnt/datadrive/DATA/LOWFS/slopes-to-TT.fits", slopes_to_TT)