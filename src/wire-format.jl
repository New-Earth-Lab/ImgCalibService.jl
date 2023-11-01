
"""
Represents the header of a VENOMS frame sent over an Aeron stream.
Given a buffer or view, provide property access to the underlying
fields without copying
"""
struct VenomsImageMessage{T<:AbstractArray{UInt8}}
    buffer::T
end

Version(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[ 1:4 ])[] 
Version!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[ 1:4 ])[] = value
PayloadType(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[ 5:8 ])[] 
PayloadType!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[ 5:8 ])[] = value
TimestampNs(vfh::VenomsImageMessage) = reinterpret(Int64, @view vfh.buffer[ 9:16])[] 
TimestampNs!(vfh::VenomsImageMessage, value) = reinterpret(Int64, @view vfh.buffer[ 9:16])[] = value
Format(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[17:20])[] 
Format!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[17:20])[] = value
SizeX(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[21:24])[] 
SizeX!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[21:24])[] = value
SizeY(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[25:28])[] 
SizeY!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[25:28])[] = value
OffsetX(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[29:32])[] 
OffsetX!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[29:32])[] = value
OffsetY(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[33:36])[] 
OffsetY!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[33:36])[] = value
PaddingX(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[37:40])[] 
PaddingX!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[37:40])[] = value
PaddingY(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[41:44])[] 
PaddingY!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[41:44])[] = value
MetadataLength(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[45:48])[] 
MetadataLength!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[45:48])[] = value
MetadataBuffer(vfh::VenomsImageMessage) = @view vfh.buffer[49:49+MetadataLength(vfh)-1] # TODO: 4-byte alignment
ImageBufferLength(vfh::VenomsImageMessage) = reinterpret(Int32, @view vfh.buffer[49+MetadataLength(vfh):49+MetadataLength(vfh)+3])[]
ImageBufferLength!(vfh::VenomsImageMessage, value) = reinterpret(Int32, @view vfh.buffer[49+MetadataLength(vfh):49+MetadataLength(vfh)+3])[]= value
function ImageBuffer(vfh::VenomsImageMessage)
    start = 49+MetadataLength(vfh)+4
    len = ImageBufferLength(vfh)
    return @view vfh.buffer[start:start+len-1]
end
function Image(vfh::VenomsImageMessage)
    Fmt = if Format(vfh) == 0x01100007
        Int16
    elseif Format(vfh) == 9
        Float32
    elseif Format(vfh) == 10
        Float64
    else
        error("Format not yet supported")
    end
    return reshape(reinterpret(Fmt, ImageBuffer(vfh)), Int64(SizeX(vfh)), Int64(SizeY(vfh)))
end
# Faster version: assumes data types are not changing!
function Image(DType, vfh::VenomsImageMessage)
    if DType == Int16 && Format(vfh) == 0x01100007
    elseif DType == Float32 && Format(vfh) == 9
    elseif DType == Float64 && Format(vfh) == 10
    else
        error(lazy"Data type from stream ($(Format(vfh)) does not match provided type ($DType).")
    end
    return reshape(reinterpret(DType, ImageBuffer(vfh)), Int64(SizeX(vfh)), Int64(SizeY(vfh)))
end
# Warning: assumes data types are not changing!
# TODO: throw an error if they do.
function Image!(output::AbstractArray{T}, vfh::VenomsImageMessage) where T
    if pointer(output) == pointer(ImageBuffer(vfh))
        return
    end
    copyto!(output, reinterpret(T, ImageBuffer(vfh)))
end
