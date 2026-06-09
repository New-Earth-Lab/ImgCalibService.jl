Hsm.add_state!(sm, name = :Waiting, ancestor=:Top)
Hsm.add_state!(sm, name = :Ready, ancestor=:Top)
    Hsm.add_state!(sm, name = :Processing, ancestor=:Ready)
        Hsm.add_state!(sm, name = :Playing, ancestor=:Processing)
        Hsm.add_state!(sm, name = :Paused, ancestor=:Processing)
    Hsm.add_state!(sm, name = :Stopped, ancestor=:Ready)
Hsm.add_state!(sm, name = :Error, ancestor=:Top)
Hsm.add_state!(sm, name = :Exited, ancestor=:Top)

Hsm.on_initial!(sm, :Top) do 
    Hsm.transition!(sm, :Waiting)
end
Hsm.on_initial!(sm, :Ready) do 
    GC.gc(true)
    Hsm.transition!(sm, :Processing)
end
Hsm.on_initial!(sm, :Processing) do 
    Hsm.transition!(sm, :Paused)
end

Hsm.on_event!(sm, :Top, :Error) do 
    Hsm.transition!(sm, :Error)
end

# # Buffer used to report our current state to listners who connect late and want to catch up.
# const status_report_buffer = zeros(UInt8,1024)
# const status_report_msg = EventMessage(status_report_buffer)
# resize!(status_report_buffer, sizeof(status_report_msg))
# const status_report_argument_buffer = zeros(UInt8,1024)


# Hsm.on_event!(sm, :Top, :StatusRequest) do payload
#     event_info = EventMessage(payload, initialize=false)

#     # Send each paramter
#     vars_nt = RTCBlock.statevariables(sm)
#     for key in keys(vars_nt)
#         status_report_msg.name = String(key) # allocates
#         # TODO: constuct array message if needed
#         val = vars_nt[key]
#         setargument!(status_report_msg,nothing)
#         resize!(status_report_argument_buffer, sizeof(status_report_msg))
#         if val isa AbstractArray
#             resize!(status_report_argument_buffer, sizeof(val)+512)
#             arr_message = ArrayMessage(status_report_argument_buffer)
#             arraydata!(arr_message, val)
#             resize!(status_report_argument_buffer, sizeof(arr_message))
#             resize!(status_report_buffer, sizeof(status_report_msg)+sizeof(status_report_argument_buffer))
#         else
#             resize!(status_report_buffer, sizeof(status_report_msg)+sizeof(val))
#             setargument!(status_report_msg, val)
#         end
#         status_report_msg.header.TimestampNs = 0 # TODO
#         status_report_msg.header.correlationId = event_info.header.correlationId
#         resize!(status_report_buffer, sizeof(status_report_msg))
#         Aeron.put!(pub_status, status_report_buffer)
#     end
#     # Send the overall state
#     status_report_msg.name = cstatic"state"
#     setargument!(status_report_msg, String(Hsm.current(sm))) # Note: this allocates.
#     status_report_msg.header.TimestampNs = 0 # TODO
#     status_report_msg.header.correlationId = event_info.header.correlationId
#     resize!(status_report_buffer, sizeof(status_report_msg))
#     Aeron.put!(pub_status, status_report_buffer)
#     return Hsm.Handled
# end

Hsm.on_event!(sm, :Error, :Reset) do payload
    Hsm.transition!(sm, :Waiting)
    return Hsm.Handled
end
Hsm.on_event!(sm, :Ready, :Reset) do payload
    Hsm.transition!(sm, :Waiting)
    return Hsm.Handled
end

Hsm.on_event!(sm, :Top, :Exit) do payload
    Hsm.transition!(sm, :Exited)
    return Hsm.Handled
end


Hsm.on_event!(sm, :Ready, :Play) do payload
    Hsm.transition!(sm, :Playing)
    return Hsm.Handled
end
Hsm.on_event!(sm, :Ready, :Pause) do payload
    Hsm.transition!(sm, :Paused)
    return Hsm.Handled
end
Hsm.on_event!(sm, :Processing, :Play) do payload
    Hsm.transition!(sm, :Playing)
    return Hsm.Handled
end
Hsm.on_event!(sm, :Processing, :Pause) do payload
    Hsm.transition!(sm, :Paused)
    return Hsm.Handled
end
Hsm.on_event!(sm, :Processing, :Stop) do payload
    Hsm.transition!(sm, :Stopped)
    return Hsm.Handled
end


Hsm.on_entry!(sm, :Exited) do 
    @info "Exiting."
    exit(0)
end


Hsm.on_entry!(sm, :Error) do 
    @error "error state"
end