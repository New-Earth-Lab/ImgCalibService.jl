function measure_response_matrix(
    camera,
    dm,
    modemat,
    coadds=50,
    N_frame_wait=2
)
    img = capture(camera)
    intermat = zeros(size(img)...,size(modemat,1), coadds)
    # TODO: once we have multiple channels we can just put 0 instead
    # of restoring previous command
    offset = getact(dm)
    # Note: we go through all modes one co add at  a time. 
    # The hope is this prevents any drift during measurements ending up all in one mode
    for (i_mode, mode) in enumerate(eachrow(modemat))
        sleep(0.100)
        setact!(dm, offset .+ mode)
        for i_coadd in 1:coadds

            capture!(img, camera)
            # Skip frames to wait for DM to settle
            for i_wait in 1:N_frame_wait
                capture!(img,camera)
            end
            capture!(img,camera)
            intermat[:,:,i_mode,i_coadd] += img./sum(img)
        end
        sleep(0.100)
        setact!(dm, offset .- mode)
        for i_coadd in 1:coadds
            # Skip frames to wait for DM to settle
            for i_wait in 1:N_frame_wait
                capture!(img,camera)
            end
            capture!(img,camera)
            intermat[:,:,i_mode,i_coadd] -= img./sum(img)
            # note: we are dividing by the total flux to normalize out source intensity variations
        end
    end
    setact!(dm, offset)
    intermat = @views median(intermat,dims=4)[:,:,:]
    intermat .= intermat ./ 2

    return intermat
end

using MAT
using AstroImages
using LinearAlgebra
using Statistics
t = Threads.@spawn begin
    
    camera = connectdevice("GoldEye")
    dm = connectdevice("ALPAO468")

    modemat = collect(Diagonal(fill(0.2, 468)))

    # Capture a reference image. This can be updated separately from the main calibration
    reference_image = median(stack([
        capture(camera)
        for _ in 1:30
    ]),dims=3)[:,:]

    # Divide response matrix by the total intensity of the reference image
    # This prevents a flux-dependent signal
    reference_image ./= sum(reference_image)
    save("/mnt/datadrive/DATA/LOWFS/reference-image.fits", reference_image)

    # Capture interaction matrix (it's differential so no ref. image needed)
    # N_X_pix * N_Y_pix
    response_mat = measure_response_matrix(
        camera,
        dm,
        modemat,
    )
    @info "recorded response matrix"
    # Same differential imaged for visualizing etc.
    save("/mnt/datadrive/DATA/LOWFS/poke-images.fits",response_mat)

end
fetch(t)