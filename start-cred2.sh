#!/bin/bash
export SUB_CONTROL_URI='aeron:ipc'
export SUB_CONTROL_STREAM=601
export PUB_STATUS_URI='aeron:ipc'
export PUB_STATUS_STREAM=602
export SUB_DATA_URI_1='aeron:ipc'
export SUB_DATA_STREAM_1=2011
export SUB_DATA_LATE_DATA_DROP_SEC_1="1.5e-3"
export PUB_DATA_URI='aeron:ipc'
export PUB_DATA_STREAM=1011

export JULIA_PROJECT=/opt/spiders/imgcalibservice/
export JULIA_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
# export JULIA_LIKWID_PIN="S0:10"

julia +1.10 -e "using ImgCalibService; ImgCalibService.main(ARGS)"
