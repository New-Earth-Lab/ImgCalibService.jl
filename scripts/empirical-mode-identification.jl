function measure_response_matrix(
    camera,
    dm,
    modemat,
    N_frame_wait=2,
    t_ministep=0.0002,
    N_coadds=50
)

    # Speedy busy sleep.
    function minisleep(t)
        stop_time = time() + t
        while time() < stop_time
        end
    end
    img = capture(camera)
    intermat = zeros(size(img)...,size(modemat)[2:3]...)
    # TODO: once we have multiple channels we can just put 0 instead
    # of restoring previous command
    offset = collect(getact(dm))
    for i_mode in axes(modemat,3)
        mode = @view modemat[:,1,i_mode]
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
        for i_amp in axes(modemat,2)
            setact!(dm, offset .+ mode)
            # Skip frames to wait for DM to settle
            for i_wait in 1:N_frame_wait
                capture!(img,camera)
            end
            for i in 1:N_coadds
                capture!(img,camera)
                intermat[:,:,i_amp,i_mode] += img./sum(img)
            end
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
    intermat./=N_coadds
    setact!(dm, offset)
    setact!(dm, offset)
    capture!(img,camera)

    return intermat
end

using MAT
using AstroImages
using LinearAlgebra

camera = connectdevice("GoldEye")
dm = connectdevice("ALPAO468")

matvars = matread("/opt/VENOMS/NewEarthLab/config/BAX307-Z2C.mat")
z2c = matvars["Z2C"]

# testing

# Scale down the command strength we test with by mode #
z2c_scaled = z2c .* [1.0, 1.0, range(start=1.0,stop=0.1, length=size(z2c,1)-2)...]

# Make outer two rings the same (it seems like we can't sense well the outer ring)
x, y = axes(dm.actuator_map)
x = x .- mean(x)
y = y .- mean(y)
r = sqrt.(x.^2 .+y'.^2)
outer_ring = (r .>= 11).&& dm.actuator_map
next_ring = r .>= 10.12  .&& .! outer_ring
# imview(lowfsmodes_map[:,:,1])
# imview(lowfsmodes_map[:,:,1] .* outer_ring)
# imview(lowfsmodes_map[:,:,1] .* next_ring)

outer_ring_vec = vec(map(findall(dm.actuator_map)) do I
    I ∈ findall(outer_ring)
end)

#  Now need to find nearest neighbour of each actuator in the outer ring
# Nope! For now just zero these out.
z2c_scaled[:,outer_ring_vec].=0

# Option: create random linear combinations of the above
# z2c_scaled|>std
# s2c_shuffled = z2c_scaled .* randn.() 
# s2c_shuffled|>std

modemat = stack(
    amplitude .* z2c_scaled[i,:]
    # amplitude .* s2c_shuffled[i,:]
    for amplitude in -0.15:0.01:0.15, i in axes(z2c,1)
    # for amplitude in -0.2:0.01:0.2, i in axes(z2c,1)[1:5]
)


modematflat = reshape(modemat, 468, :)'

# Capture "interaction" matrix
# N_X_pix * N_Y_pix
t = Threads.@spawn measure_response_matrix(
    camera,
    dm,
    modemat,
)
response_mat = fetch(t)
save("/mnt/datadrive/DATA/LOWFS/empirical-mode-identification-scan.fits",response_mat)
##
reference_images = response_mat[:,:,21:21,:];

differential_responses = response_mat.-reference_images./sum(reference_images,dims=(1,2));
save("/mnt/datadrive/DATA/LOWFS/empirical-mode-identification-diff-responses.fits",differential_responses)

imview(differential_responses)
##
mat = reshape(differential_responses, :, size(response_mat,3)*size(response_mat,4));


q = svd(mat);

wfs_modes = reshape(q.U,size(reference_images)[1:2]...,:)

imview(wfs_modes[:,:,1:30])
save("/mnt/datadrive/DATA/LOWFS/empirical-mode-identification-wfs-modes.fits",wfs_modes[:,:,1:200])
# save("/home/spiders/Downloads//empirical-wfs-response.fits",wfs_modes[:,:,1:200])

##
# dm_modes_flat = q.U * modematflat
# dm_modes_flat = q.U * modematflat
# reshape(dm_modes_flat, size(modemat))

# dominant DM mode
# cmd = modematflat' * q.U[1,:]
# lowfsmodes_map = zeros(size(dm.actuator_map)...)# size(lowfsmodes,2));
# lowfsmodes_map[dm.actuator_map] .= cmd
# imview(lowfsmodes_map[:,:,1:20])

##
# dominant DM mode
cmd = collect((q.Vt * modematflat)')
save("/mnt/datadrive/DATA/LOWFS/empirical-mode-identification-dm-modes.fits",cmd)
lowfsmodes_map = zeros(size(dm.actuator_map)..., size(cmd,2));
lowfsmodes_map[dm.actuator_map,:] .= cmd
save("/mnt/datadrive/DATA/LOWFS/empirical-mode-identification-dm-modes-map.fits",lowfsmodes_map[:,:,1:200])
# save("/home/spiders/Downloads/empirical-response.fits",lowfsmodes_map[:,:,1:200])

imview(lowfsmodes_map[:,:,1:10])
# imview(lowfsmodes_map[:,:,2])

##
# setact!(dm, dm.bestflat)
# capture(camera)
# capture(camera)
# ref = capture(camera)
# setact!(dm, dm.bestflat.+5cmd[:,3])
# capture(camera)
# capture(camera)


# i = capture(camera)
# imview(i./sum(i) .- ref./sum(ref))