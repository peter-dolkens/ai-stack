# Wyoming Whisper with CUDA runtime libraries baked in.
#
# The base rhasspy/wyoming-whisper image omits libcublas and other CUDA compute
# libraries, expecting them to be injected by the host NVIDIA container runtime.
# When using CDI (devices: nvidia.com/gpu=all) without a full CUDA toolkit install
# on the host, these libraries are absent and faster-whisper fails at inference time.
#
# This image installs libcublas12 from the NVIDIA apt repo so GPU inference works
# regardless of what's installed on the host.
FROM rhasspy/wyoming-whisper

RUN apt-get update \
    && apt-get install -y --no-install-recommends wget ca-certificates \
    && wget -qO /tmp/cuda-keyring.deb \
        https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i /tmp/cuda-keyring.deb \
    && rm /tmp/cuda-keyring.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends libcublas-12-8 \
    && rm -rf /var/lib/apt/lists/*
