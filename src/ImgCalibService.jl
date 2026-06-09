module ImgCalibService
using Hsm
using Aeron
using RTCBlock
using StaticStrings
using SpidersMessageEncoding

aeron_ctx::AeronContext = AeronContext()
const event_queue::Channel{Symbol} = Channel{Symbol}(10)
const last_heartbeat = Ref(time())

include("state-machine.jl")

function main(ARGS=[])
    global aeron_ctx = AeronContext()
    RTCBlock.serve(sm, event_queue, aeron=aeron_ctx, ) do
        if time()-last_heartbeat[] > 1.0
            push!(event_queue, :StatusRequest)
            last_heartbeat[] = time()
        end
        return
    end
end
end
