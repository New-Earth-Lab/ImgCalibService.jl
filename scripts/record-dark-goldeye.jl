using Aeron
using Statistics
include("/opt/spiders/lowfsservice/src/wire-format.jl")

## Receive Images
N_frames = 850*5
input_conf = AeronConfig(
    channel="aeron:ipc",
    stream=1003,
)

darks = Aeron.subscribe(input_conf) do aeronsub
    frame, _ = iterate(aeronsub)
    header = VenomsImageMessage(frame.buffer)
    img = Image(header)


    # Spin to discard old images cached in the term buffer
    while round(UInt64, time()*1e9) - TimestampNs(header) > 5e-3*1e9
        frame, _ = iterate(aeronsub)
        header = VenomsImageMessage(frame.buffer)
    end

    return stack(map(zip(1:N_frames, aeronsub)) do (i_frame, frame)
        @info "Recording dark frame" i_frame
        header = VenomsImageMessage(frame.buffer)
        collect(Image(header))
    end)
end

using StatsBase

dark = mapslices(darks,dims=3) do px
    mean(trim(px, prop=0.1))
end[:,:]


##
using AstroImages
save("/mnt/datadrive/DATA/Goldeye/dark.fits",dark)
