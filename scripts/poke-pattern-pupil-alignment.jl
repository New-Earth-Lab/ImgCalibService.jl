using Aeron
include("/opt/spiders/lowfsservice/src/wire-format.jl")
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
const pubhead = VenomsImageMessage(buffer)
SizeX!(pubhead, 468)
SizeY!(pubhead, 1)
Format!(pubhead, 10) # Float64
MetadataLength!(pubhead,  0)
ImageBufferLength!(pubhead, 468*8)
ImageBufferLength(pubhead)

aeronpub = Aeron.publisher(output_conf)
function setact!(aeronpub, command_vec::AbstractVector{<:Number})
    for v in command_vec
        if !(-0.5 < v < 0.5)
            error("Provided DM command exceeds valid range (-0.5 < cmd < 0.5)")
        end
    end
    current_time = round(UInt64, time()*1e9) # TODO: this is messy. Unclear if the accuarcy is good.
    TimestampNs!(pubhead, current_time)
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
            @info "poke"
            setact!(dm, offset .+    mode)
            minisleep(0.015)
            for i_coadd in 1:coadds
                @info "poke +"
                frame, _ = iterate(aeronsub)
                # Skip frames to wait for DM to settle
                for i_wait in 1:N_frame_wait
                    frame, _ = iterate(aeronsub)
                end
                frame, _ = iterate(aeronsub)
                intermat[:,:,i_mode,i_coadd] += img./sum(img)
            end
            @info "poke"
            setact!(dm, offset .-    mode)
            minisleep(0.015)
            for i_coadd in 1:coadds
                @info "poke 1"
                # Skip frames to wait for DM to settle
                for i_wait in 1:N_frame_wait
                    frame, _ = iterate(aeronsub)
                end
                frame, _ = iterate(aeronsub)
                intermat[:,:,i_mode,i_coadd] -= img./sum(img)
                # note: we are dividing by the total flux to normalize out source intensity variations
            end
            @info "reset"
            setact!(dm, offset)
        end
        setact!(dm, offset)
        intermat = @views median(intermat,dims=4)[:,:,:]
        intermat .= intermat ./ 2

        return intermat
    end
end

using MAT
using AstroImages
using LinearAlgebra
using Statistics
using LinearAlgebra


matvars = matread("/opt/VENOMS/NewEarthLab/config/BAX307-Z2C.mat")
actuator_map = BitMatrix(load("/mnt/datadrive/DATA/dm/BAX307-actu-map.fits"))
z2c = matvars["Z2C"]

##

# modemat = load("/mnt/datadrive/DATA/LOWFS/modes-to-actus.fits")
# modemat = collect(Diagonal(fill(0.4, 468)))
modemat = zeros(1, 468)
modemat[1,[79, 90, 379, 390]] .= 0.4

while true

    response_mat = measure_response_matrix(
        input_conf,
        aeronpub,
        modemat,
    )

    using ImageTransformations, Interpolations
    imresize(
        imview(response_mat[:,:,1], clims=(-0.000015, 0.000015)),
        ratio=6,
        method=BSpline(Constant())
    )|>display
    sleep(4)
end

#
# Same differential imaged for visualizing etc.
#save("/mnt/datadrive/DATA/LOWFS/pupil-alignment-poke-response.fits",response_mat[:,:,1])




