module ImgCalib
using TOML
using FITSIO
using Aeron
using LinearAlgebra
using ThreadPinning
using Oxygen
using SwaggerMarkdown
using HTTP
using StructTypes
using LinearAlgebra

include("wire-format.jl")

const DType = Float32

# Hold variables used by the loop so we can update all at once
struct State
    # Camera dark
    dark::Matrix{DType}
    # Camera flat
    flat::Matrix{DType}
end

# Add a supporting struct type definition so JSON3 can serialize & deserialize automatically
StructTypes.StructType(::Type{State}) = StructTypes.Struct()

"""
    main()

The main entrypoint of the Low Order Wavefront Sensor service.

Set up a loop on the interactive thread that subscribes to the necessary
aeron streams.
"""
function main(ARGS=ARGS) # Take command line arguments or allow them to be passed in
    @info "Starting imgcalibservice"

    if Threads.nthreads(:interactive) < 1
        @warn "Ensure Julia is started with at least one interative thread for performance reasons (--threads=1,1)"
    end

    if length(ARGS) < 1
        error("missing configuration toml filepath required argument")
    end
        
    configname = ARGS[1]
    config = TOML.parsefile(configname)

    pinthreads(config["pin-threads"])

    BLAS.set_num_threads(config["blas-threads"])

    aeron_input_stream_config = AeronConfig(
        channel=config["input-channel"],
        stream=config["input-stream"],
    )

    aeron_output_stream_config = AeronConfig(
        channel=config["output-channel"],
        stream=config["output-stream"],
    )

    rest_api_port = config["rest-api-port"]


    dark = FITS(config["state"]["dark"],"r") do fitsfile
        read(fitsfile[1])
    end
    flat = FITS(config["state"]["flat"],"r") do fitsfile
        read(fitsfile[1])
    end

    initial_state = State(dark, flat)
    current_state_slot = Ref(initial_state)

    register_rest_api(config, current_state_slot)

    if size(dark) != size(flat)
        error(lazy"Incompatible dimensions detected size(flat)=$(size(flat)) size(dark)=$(size(dark))")
    end
    
    looptask = Threads.@spawn :default loopmanager(
        aeron_input_stream_config,
        aeron_output_stream_config,
        current_state_slot
    )

    # Watch and report any errors here
    # In future we can write our own error handling, but this way exceptions don't silenty disappear.
    errormonitor(looptask)

    # start the web server
    resttask = Threads.@spawn :interactive serve(;port=rest_api_port)

    try
        run(`systemd-notify --ready`)
    catch
    end


    # TODO: we don't have a way to cleanly shutdown everything yet
    wait(looptask)
    wait(resttask)

    # Can't get here unless we hit an error
    return 0
end


# This function should be called on an interactive thread
function loopmanager(
    aeron_input_stream_config,
    aeron_output_stream_config,
    current_state_slot,
)
    @info "Starting loop" Threads.threadpool() Threads.nthreads() Threads.threadid()

    # Intialize variables
    # initial_state = current_state_slot[] # Currently unused
    
    # Subscribe to the incoming stream
    Aeron.subscribe(aeron_input_stream_config) do subscription

        @info "Subscribed to aeron stream " aeron_input_stream_config


        first_message = first(subscription)
        first_message = VenomsImageMessage(first_message.buffer)
        img_in = Image(Int16, first_message)
        img_scratch = zeros(DType, size(img_in))
    
        # Prepare our publication stream: where we output measurements
        Aeron.publisher(aeron_output_stream_config) do publication
            
            @info "Publishing to aeron stream " aeron_output_stream_config

            # Set up our data to publish
            pub_buffer = zeros(UInt8, length(first_message.buffer)*2)
            pub_header = VenomsImageMessage(pub_buffer)
            SizeX!(pub_header, SizeX(first_message))
            SizeY!(pub_header, SizeY(first_message))
            Format!(pub_header, 9) # Float32
            MetadataLength!(pub_header, MetadataLength(first_message))
            ImageBufferLength!(pub_header, ImageBufferLength(first_message)*2)
            pub_data = Image(pub_header)

            # Now that we've done all the set up work, enable GC logging so we can keep an eye on things
            GC.enable_logging()

            for framereceived in subscription
                # Read the current state of loop in one go, so it can't change
                # while we are working through one iteration
                state = current_state_slot[]
                
                # Decode message
                message = VenomsImageMessage(framereceived.buffer)
                Image!(img_in, message)

                # Upconvert to float while subtracting reference image
                img_scratch .= img_in .- state.dark

                # Apply flat correction and place into output data
                pub_data .= img_scratch ./ state.flat

                TimestampNs!(pub_header, TimestampNs(message))
                
                # Publish corrected image
                status = Aeron.publication_offer(publication, pub_header.buffer)
                if status == :adminaction
                    @warn lazy"could not publish wavefront measurement ($status)"
                elseif status == :backpressured
                    @warn lazy"could not publish wavefront measurement ($status)"
                elseif status != :success && status != :backpressured && status != :notconnected
                    error(lazy"could not publish wavefront sensor measurement ($status)")
                end

            end
        end
    end
end


## REST API ##
function register_rest_api(config, current_state_slot)

    # Note for the technically inclined: Oxygen.jl is wrapping HTTP.jl.
    # These macros are adding request handlers to a default global route
    # stored in Oxygen.ROUTER. That's how the server knows about them.
    # This approach would not allow multiple servers on different ports

    @get "/" function(req::HTTP.Request)
        # Home page message
        return html("<h1>imgcalibservice</h1> <a href=\"/docs\">/docs</a>")
    end


    @get "/state" function(req::HTTP.Request)
        return current_state_slot[]
    end

    # Atomically load new ref image and matrices, swap at next loop iteration.
    @post "/state" function(req::HTTP.Request)
        qp = queryparams(req)
        # current_state = current_state_slot[] # Not currently needed

        path = get(qp, "dark", config["state"]["dark"])
        dark = FITS(path,"r") do fitsfile
            read(fitsfile[1])
        end

        path = get(qp, "flat", config["state"]["flat"])
        flat = FITS(path,"r") do fitsfile
            read(fitsfile[1])
        end

        new_state = State(dark, flat)
        current_state_slot[] = new_state

        return true
    end

    @get "/shutdown" function(req::HTTP.Request)
        # TODO: signal loop that it needs to exit cleanly. For now we'll just quit.
        exit(0)
    end

end

# have processing "state"
# other states:
# initialization
# error state or well outside of rate -> jump to idle state

end