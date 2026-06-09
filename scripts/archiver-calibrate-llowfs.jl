using Dates
date = Dates.format(Dates.now(), "yyyy-mm-dd")
dbfname = "/mnt/datadrive/DATA/$date/INDEX-$date.sqlite"

t_integ_s = 0.1
t_wait_s = 0.05
## Aeron stream numbers
goldeye_stream = 1013
cred2_stream = 1011
dm_user_off_stream = 104#103
dm_total_stream = 105

##
using SpidersMessageEncoding
using SpidersMessageSender
using AstroImages
using LinearAlgebra
using Statistics
using ArchiverService: select_messages, indices_corr_range

# Our LOWFS modes to calibrate.
# modemat = load("/mnt/datadrive/DATA/LOWFS/modes-to-actus.fits")
modemat = load("/mnt/datadrive/DATA/LOWFS/lowfs-modes-to-actus.fits")
cmd_scale = 10

# We also want frames that will become our reference image, which have the DM flat.
flat = zeros(Float32, 468)
modemat_with_flat = [flat'; modemat[1:end,:]]
# reduce amplitude by factor 10
modemat_with_flat ./= cmd_scale

## Connect to the archiver service, and DM service
using Aeron
ctx = AeronContext()

pub_arch = Aeron.publisher(ctx, AeronConfig(uri="aeron:ipc", stream=201))
pub_dm = Aeron.publisher(ctx, AeronConfig(uri="aeron:ipc", stream=dm_user_off_stream))


## Run calibration

# Tell the archiver Start recording
sendevents(pub_arch, uri="aeron:ipc", stream=goldeye_stream, enabled=1, )
sendevents(pub_arch, uri="aeron:ipc", stream=dm_user_off_stream, enabled=1, )
sendevents(pub_arch, uri="aeron:ipc", stream=dm_total_stream,    enabled=1, )
sleep(1.0)
corr_num_start, _ = sendarray(pub_dm, Float32.(flat), description="calibration")

# Send pushes and pulls
corr_nums = []
for mode in eachrow(modemat_with_flat)

    # Push and pull DM command. Let DM settle in-between.
    sendarray(pub_dm, Float32.(mode), description="calibration")
    sleep(t_wait_s)
    corr_start_push, _ = sendarray(pub_dm, Float32.(mode), description="calibration")
    sleep(t_integ_s)
    corr_stop_push, _ = sendarray(pub_dm, Float32.(-mode), description="calibration")

    sendarray(pub_dm, Float32.(mode), description="calibration")
    sleep(t_wait_s)
    corr_start_pull, _ = sendarray(pub_dm, Float32.(-mode), description="calibration")
    sleep(t_integ_s)
    corr_stop_pull, _ = sendarray(pub_dm, Float32.(flat), description="calibration")
    
    # Store the starting and ending correlation numbers for the push and pull
    c = (;corr_start_push, corr_stop_push, corr_start_pull, corr_stop_pull)
    push!(corr_nums, c)
    
    println("Poked mode ", c)
    sleep(t_wait_s)
end
corr_num_stop, _ = sendarray(pub_dm, Float32.(flat), description="calibration")


# Stop Recording
sendevents(pub_arch, uri="aeron:ipc", stream=goldeye_stream, enabled=0, )
sendevents(pub_arch, uri="aeron:ipc", stream=dm_user_off_stream, enabled=0, )
sendevents(pub_arch, uri="aeron:ipc", stream=dm_total_stream, enabled=0 )

# Set back to flat
sendarray(pub_dm, Float32.(flat), description="calibration")

println("DONE DONE")
sleep(1)
## From here on out, we are just assebling the data and preparing the necessary calibration files.


## Full calibration movie:

# Optional: dump all images and DM commands into a big FITS cube for inspection.
#ii = indices_corr_range(dbfname, goldeye_stream, corr_num_start, corr_num_stop)
#rm("$dbfname/lowfs-calib-recording.fits")
#save_messages(dbfname, ii, "$dbfname/lowfs-calib-recording.fits")
##

function cog(img)
    tot = sum(img)
    X = sum(img .* axes(img,1))/tot
    Y = sum(img .* axes(img,2)')/tot
    return X, Y
end

# Have to wait for data to be purged to disk
for i in 1:20
    try
        jj = indices_corr_range(dbfname, [goldeye_stream], corr_nums[1].corr_start_push, corr_nums[1].corr_stop_pull)
        if length(jj) > 0
            break
        end
    catch
        sleep(1)
    end
    if i == 20
        @error "could not find range"
    end
end
ii = indices_corr_range(dbfname, [goldeye_stream], corr_nums[1].corr_start_push, corr_nums[1].corr_stop_pull)
ref_images = select_messages(TensorMessage, dbfname, ii);
reference_image = mean(arraydata.(ref_images))
imview(reference_image)

# Divide response matrix by the total intensity of the reference image
# This prevents a flux-dependent signal
reference_image ./= sum(reference_image)
save("/mnt/datadrive/DATA/LOWFS/reference-image.fits", Float32.(reference_image))

# Fill in COG pixels and mask
cog_image_mask = falses(size(reference_image))
cog_image_mask[10 .< axes(reference_image,1) .< 90,:] .= true
imview(cog_image_mask .* reference_image)

Xx, Yy = cog(cog_image_mask .* reference_image)

save("/mnt/datadrive/DATA/LOWFS/cog-image-mask.fits",UInt8.(cog_image_mask))
save("/mnt/datadrive/DATA/LOWFS/cog-reference.fits",Float32.([Xx,Yy]))

## Now look at second and third mode to see CoG respones to TT

# Wait for data to hit disk
for i in 1:20
    try
        indices_corr_range(dbfname, [goldeye_stream], corr_nums[3].corr_start_push, corr_nums[3].corr_stop_pull)
        break
    catch
        sleep(1)
    end
end
ii_push = indices_corr_range(dbfname, [goldeye_stream], corr_nums[2].corr_start_push, corr_nums[2].corr_stop_push);
ii_pull = indices_corr_range(dbfname, [goldeye_stream], corr_nums[2].corr_start_pull, corr_nums[2].corr_stop_pull);
tip_push = mean(arraydata.(select_messages(TensorMessage, dbfname, ii_push)))
tip_pull = mean(arraydata.(select_messages(TensorMessage, dbfname, ii_pull)))

ii_push = indices_corr_range(dbfname, [goldeye_stream], corr_nums[3].corr_start_push, corr_nums[3].corr_stop_push);
ii_pull = indices_corr_range(dbfname, [goldeye_stream], corr_nums[3].corr_start_pull, corr_nums[3].corr_stop_pull);
tilt_push = mean(arraydata.(select_messages(TensorMessage, dbfname, ii_push)))
tilt_pull = mean(arraydata.(select_messages(TensorMessage, dbfname, ii_pull)))

imview(tip_push .* cog_image_mask)
imview(tip_pull .* cog_image_mask)
imview(tilt_push .* cog_image_mask)
imview(tip_pull .* cog_image_mask)

# TODO There is probably a cleaner way to fill this
response_mat_cog = zeros(2,2)

# Tip
x,y = cog(tip_push .* cog_image_mask)
response_mat_cog[1,1] += x
response_mat_cog[2,1] += y
x,y = cog(tip_pull .* cog_image_mask)
response_mat_cog[1,1] -= x
response_mat_cog[2,1] -= y

# Tilt
x,y = cog(tilt_push .* cog_image_mask)
response_mat_cog[1,2] += x
response_mat_cog[2,2] += y
x,y = cog(tilt_pull .* cog_image_mask)
response_mat_cog[1,2] -= x
response_mat_cog[2,2] -= y

response_mat_cog .*= 4# push-pull / 2 ? 


interaction_mat_cog  = inv(response_mat_cog)
slopes_to_TT = collect(transpose(interaction_mat_cog))
save("/mnt/datadrive/DATA/LOWFS/slopes-to-TT.fits", Float32.(slopes_to_TT))

## Now look at differntial response to higher modes

"""
Given push and pull start and stop correlation numbers, compute the average push-pull image.
"""
function diffresponces(; corr_start_push, corr_stop_push, corr_start_pull, corr_stop_pull)
    ii_push = indices_corr_range(dbfname, [goldeye_stream], corr_start_push, corr_stop_push)
    ii_pull = indices_corr_range(dbfname, [goldeye_stream], corr_start_pull, corr_stop_pull)
    push = mean(arraydata.(select_messages(TensorMessage, dbfname, ii_push))) 
    pull = mean(arraydata.(select_messages(TensorMessage, dbfname, ii_pull))) 
    push ./= sum(push)
    pull ./= sum(pull)
    push_minus_pull = (push .- pull)./2
    return push_minus_pull
end

response_mat = zeros(size(reference_image)...,size(modemat_with_flat,1)-1)
for i_mode in eachindex(corr_nums)[2:end]
    response_mat[:,:,i_mode-1] = diffresponces(;corr_nums[i_mode]...)
end


# Same differential imaged for visualizing etc.
save("/mnt/datadrive/DATA/LOWFS/differential-response-images.fits",Float32.(response_mat))

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
flattened_images = response_mat[image_mask,:] .* cmd_scale .* cmd_scale .* cmd_scale ./ 2

# TODO: might need svd / Tiknohov regularisation
# interaction_mat  = pinv(flattened_images)

svd_modes = 10

out     = svd(flattened_images)
S       = copy(out.S)
S_trunc = copy(out.S)
# # regu        = "No Regularisation"   

# # Apply SVD cutoff
# # if regu == "Truncation"
#     S_trunc[svd_modes:end] .= 0
#     A_cut = out.U * Diagonal(S_trunc) * out.Vt
# elseif regu == "Tiknohov"
    S_trunc = (S .^2 .+ S[svd_modes] ^ 2) ./ S 
    A_cut = out.U * Diagonal(S_trunc) * out.Vt
# elseif regu == "No Regularisation"
    # A_cut = out.U * Diagonal(out.S) * out.Vt
# end 
interaction_mat = A_cut'

# # TODO: I could just rotate the DM commands into the 5 SVD modes now.
# interaction_mat  = flattened_images'

image_to_modes = collect(transpose(interaction_mat))
save("/mnt/datadrive/DATA/LOWFS/image-to-modes.fits", Float32.(image_to_modes))

##