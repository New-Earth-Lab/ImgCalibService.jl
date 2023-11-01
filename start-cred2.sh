#!/bin/bash
# Start with current project activated, two general threads, and one thread in the interactive threadpool
# Default arugment value: /opt/spiders/imgcalib/config.toml
julia +1.10 --project=/opt/spiders/imgcalibservice/ --threads 1,1 --gcthreads=1 -e "using ImgCalib; ImgCalib.main(ARGS)" -- ${1:-/opt/spiders/imgcalibservice/cred2-config.toml}
