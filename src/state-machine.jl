using LinearAlgebra
using Printf# This component is a multi-DM channel mixer and outer for an ALPAO DM.

# Channels are created dynamically when we receive a command with a new description
# Channels are "sticky" in that the most recent command is kept until changed
# The values of all channels are summed together along with the bestflat
# and placed into dither_detpoint.

const DType = Float32

# These are our variables for the service plus a state machine context to keep
# track of our current state.
Base.@kwdef mutable struct ImgCalHSM <: Hsm.AbstractStateMachine
    # This tracks the state of the block
    context::Hsm.StateMachineContext=Hsm.StateMachineContext()

    ####### These are our set-able variables
    # The reference image is a vector of just the valid pixels
    dark::Matrix{DType}=zeros(DType,0,0)
    dark_set::Bool=false
    # A matrix of valid pixel locations
    flat::Matrix{DType}=ones(DType,0,0)
    flat_set::Bool=false

    ######## These are our working variables / scratch spaces
    # Vector of valid pixels (of correct length = count of true in image_mask) for us to work on
    # Image scratch space 
    image_scratch::Matrix{DType}=zeros(DType,0,0)
    TT::Vector{DType}=zeros(DType,2)

    output_channel::Union{Nothing,Aeron.AeronPublication}=nothing
    output_buffer::Vector{UInt8}=zeros(UInt8,2^21)

    # Secondary publication: a decimated and/or averaged copy of the calibrated
    # output, intended for slow consumers (e.g. GUIs) that would otherwise
    # backpressure the primary stream.
    decimated_output_channel::Union{Nothing,Aeron.AeronPublication}=nothing
    decimated_output_buffer::Vector{UInt8}=zeros(UInt8,2^21)
    decimated_accumulator::Matrix{DType}=zeros(DType,0,0)
    decimated_frame_count::Int=0
    # When averaging_frames > 1, accumulate N frames then publish the average.
    # When averaging_frames <= 1, publish input frames throttled to
    # decimated_min_interval_ns between sends.
    decimated_averaging_frames::Int=1
    decimated_min_interval_ns::Int64=round(Int64, (1/30)*1e9)
    decimated_last_publish_ns::Int64=0
end

# These variables are the externally visible state 
# that will be reported to any listeners when requested.
RTCBlock.statevariables(sm::ImgCalHSM) = (;
    dark=    sm.dark_set ? sm.dark : nothing,
    flat=    sm.flat_set ? sm.flat : nothing,
    decimated_averaging_frames = Float64(sm.decimated_averaging_frames),
    decimated_min_interval_s = sm.decimated_min_interval_ns / 1e9,
)

const sm = ImgCalHSM()

include("generic-state-machine.jl")

const MCL_CURRENT = 1  # Lock all current pages
const MCL_FUTURE = 2   # Lock all future pages
const MCL_ONFAULT = 4  # Lock pages when they are faulted in (Linux 4.4+)

Hsm.on_entry!(sm, :Waiting) do 
    sm.dark_set=false
    sm.flat_set=false
end

# Next steps:
# we actually need to receive the masks first before the other properties.
# Then use the masks to select the right pixels.

# Receive properties
Hsm.on_event!(sm, :Top, :dark) do payload
    event_info = EventMessage(payload, initialize=false)
    # The value is stored as an array message inside
    payload = getargument(ArrayMessage{Float32,2}, event_info)
    sm.dark = collect(arraydata(payload)) # allocates
    sm.dark_set = true
    put!(event_queue, :StartIfReady)
    return Hsm.Handled
end
Hsm.on_event!(sm, :Top, :flat) do payload
    event_info = EventMessage(payload, initialize=false)
    # The value is stored as an array message inside
    payload = getargument(ArrayMessage{Float32,2}, event_info)
    sm.flat = collect(arraydata(payload)) # allocates
    sm.flat_set = true
    put!(event_queue, :StartIfReady)
    return Hsm.Handled
end
# Runtime configuration of the secondary decimated/averaged stream. These can
# be sent at any time; the upstream GUI sends them when the user changes the
# averaging controls so the upstream service does the heavy lifting and only
# emits frames at the reduced cadence.
Hsm.on_event!(sm, :Top, :decimated_averaging_frames) do payload
    event_info = EventMessage(payload, initialize=false)
    n = max(1, round(Int, getargument(Float64, event_info)))
    sm.decimated_averaging_frames = n
    sm.decimated_frame_count = 0
    if length(sm.decimated_accumulator) > 0
        fill!(sm.decimated_accumulator, 0)
    end
    return Hsm.Handled
end
Hsm.on_event!(sm, :Top, :decimated_min_interval_s) do payload
    event_info = EventMessage(payload, initialize=false)
    s = max(0.0, getargument(Float64, event_info))
    sm.decimated_min_interval_ns = round(Int64, s * 1e9)
    return Hsm.Handled
end

Hsm.on_event!(sm, :Waiting, :StartIfReady) do payload
    if sm.dark_set && sm.flat_set

        if size(sm.flat) != size(sm.dark)
            @error("Image calibration files do not have compatible dimensions: dark=$(size(sm.dark)), flat=$(size(sm.dark))")
            Hsm.transition!(sm, :Error)
        end

        sm.image_scratch = zeros(DType, size(sm.dark))

        Hsm.transition!(sm, :Processing)
        return Hsm.Handled
    end
    return Hsm.NotHandled
end

Hsm.on_entry!(sm, :Ready) do

    conf = AeronConfig(
        uri=ENV["PUB_DATA_URI"],
        stream=parse(Int, ENV["PUB_DATA_STREAM"]),
    )
    sm.output_channel = Aeron.publisher(aeron_ctx, conf)

    # Optional secondary publication for a decimated/averaged copy of the output.
    # Configured by env vars:
    #   PUB_DATA_DECIMATED_URI            (required to enable the secondary stream)
    #   PUB_DATA_DECIMATED_STREAM         (required to enable the secondary stream)
    #   PUB_DATA_DECIMATED_MIN_INTERVAL_S (optional, default 1/30s -> 30fps)
    #   PUB_DATA_DECIMATED_AVG_FRAMES     (optional, default 1 -> decimate only)
    if haskey(ENV, "PUB_DATA_DECIMATED_URI") && haskey(ENV, "PUB_DATA_DECIMATED_STREAM")
        decimated_conf = AeronConfig(
            uri=ENV["PUB_DATA_DECIMATED_URI"],
            stream=parse(Int, ENV["PUB_DATA_DECIMATED_STREAM"]),
        )
        sm.decimated_output_channel = Aeron.publisher(aeron_ctx, decimated_conf)
        if haskey(ENV, "PUB_DATA_DECIMATED_MIN_INTERVAL_S")
            sm.decimated_min_interval_ns = round(Int64,
                parse(Float64, ENV["PUB_DATA_DECIMATED_MIN_INTERVAL_S"]) * 1e9)
        end
        if haskey(ENV, "PUB_DATA_DECIMATED_AVG_FRAMES")
            sm.decimated_averaging_frames = max(1,
                parse(Int, ENV["PUB_DATA_DECIMATED_AVG_FRAMES"]))
        end
        sm.decimated_frame_count = 0
        sm.decimated_last_publish_ns = 0
    end

    ret = @ccall mlockall((MCL_CURRENT | MCL_FUTURE)::Cint)::Cint
    if ret != 0
        error("mlockall failed with error code: $ret")
    end

    return
end
Hsm.on_exit!(sm, :Ready) do
    if !isnothing(sm.output_channel)
        close(sm.output_channel)
        sm.output_channel = nothing
    end
    if !isnothing(sm.decimated_output_channel)
        close(sm.decimated_output_channel)
        sm.decimated_output_channel = nothing
    end
    return
end

# Hsm.on_entry!(sm, :Stopped) do 
# end

Hsm.on_exit!(sm, :Processing) do 
    sm.dark_set=false
    sm.flat_set=false
end

Hsm.on_entry!(sm, :Paused) do 
end


Hsm.on_event!(sm, :Paused, :Data) do payload
    return Hsm.Handled
end

Hsm.on_event!(sm, :Playing, :Data) do payload
    # Decode message
    msg_in = ArrayMessage{DType,2}(payload)
    img_in = arraydata(msg_in)
    if !(size(img_in) == size(sm.flat) == size(sm.dark))
        @error("Image calibration files do not have compatible dimensions: input=$(size(img_in)), dark=$(size(sm.dark)), flat=$(size(sm.dark))")
        Hsm.transition!(sm, :Error)
    end
    img_in .= (img_in .- sm.dark) ./ sm.flat
    
    # sm.image_scratch .= (img_in .- sm.dark) ./ sm.flat

    # New implementation -- we don't have to copy anything! just modify the data *in place*


    # output_msg = ArrayMessage{DType,2}(sm.output_buffer)
    # arraydata!(output_msg, sm.image_scratch)
    # output_msg.header.correlationId = msg_in.header.correlationId
    # output_msg.header.TimestampNs = msg_in.header.TimestampNs

    # status = Aeron.publication_offer(sm.output_channel, view(sm.output_buffer, 1:sizeof(sm.output_buffer)))

    status = Aeron.publication_offer(sm.output_channel, payload)


    if status == :adminaction
        @warn lazy"could not publish ($status)"
    elseif status == :backpressured
        @warn lazy"could not publish (backpressured)"
    elseif status != :success && status != :notconnected
        error(lazy"could not publish ($status)")
    end

    # Best-effort publish onto the secondary decimated/averaged stream.
    # Done *after* the primary publish so this path never adds latency to it.
    if !isnothing(sm.decimated_output_channel)
        publish_decimated!(sm, payload, msg_in, img_in)
    end

    return Hsm.Handled
end

# Publish a decimated and/or averaged copy of the calibrated frame to the
# secondary publication. Uses zero retries on backpressure so a slow consumer
# (e.g. a GUI) cannot stall this service.
function publish_decimated!(sm::ImgCalHSM, payload, msg_in, img_in)
    N = sm.decimated_averaging_frames
    if N > 1
        # Averaging mode: accumulate N calibrated frames and publish their mean.
        # Output is also capped at one publish per min_interval; if a batch
        # completes too soon after the previous publish, we drop the batch and
        # start the next averaging window fresh.
        if size(sm.decimated_accumulator) != size(img_in)
            sm.decimated_accumulator = zeros(DType, size(img_in))
            sm.decimated_frame_count = 0
        end
        sm.decimated_accumulator .+= img_in
        sm.decimated_frame_count += 1
        if sm.decimated_frame_count >= N
            now_ns = round(Int64, time()*1e9)
            if now_ns - sm.decimated_last_publish_ns >= sm.decimated_min_interval_ns
                sm.decimated_accumulator ./= sm.decimated_frame_count
                out_msg = ArrayMessage{DType,2}(sm.decimated_output_buffer)
                arraydata!(out_msg, sm.decimated_accumulator)
                out_msg.header.correlationId = msg_in.header.correlationId
                out_msg.header.TimestampNs = msg_in.header.TimestampNs
                Aeron.publication_offer(
                    sm.decimated_output_channel,
                    view(sm.decimated_output_buffer, 1:sizeof(out_msg)),
                    false, # robust=false -> no retries on backpressure
                )
                sm.decimated_last_publish_ns = now_ns
            end
            fill!(sm.decimated_accumulator, 0)
            sm.decimated_frame_count = 0
        end
    else
        # Decimation mode: throttle to one publish per min_interval.
        now_ns = round(Int64, time()*1e9)
        if now_ns - sm.decimated_last_publish_ns >= sm.decimated_min_interval_ns
            Aeron.publication_offer(
                sm.decimated_output_channel,
                payload,
                false, # robust=false -> no retries on backpressure
            )
            sm.decimated_last_publish_ns = now_ns
        end
    end
    return
end
