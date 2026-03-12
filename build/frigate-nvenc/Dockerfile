# Stage 1: Build ffmpeg 8.0.1 with nv-codec-headers 13.x (compatible with NVIDIA driver 570+/580+)
# The stock Frigate image ships ffmpeg 7.0 built against nv-codec-headers 12.x, which fails
# with "incompatible client key" on driver 580.x (NVENC API v13 required).
FROM debian:bookworm-slim AS ffmpeg-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git pkg-config nasm yasm ca-certificates \
    libssl-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# nv-codec-headers v13.0.19.0 — matches NVIDIA Video Codec SDK 13 (driver 570+)
RUN git clone --depth 1 -b n13.0.19.0 https://github.com/FFmpeg/nv-codec-headers.git \
    && cd nv-codec-headers && make install && cd .. && rm -rf nv-codec-headers

# Build x264 as static library so FFmpeg bundles it without runtime .so dependency
RUN git clone --depth 1 https://code.videolan.org/videolan/x264.git \
    && cd x264 && ./configure --prefix=/opt/x264 --enable-static --disable-shared --disable-opencl \
    && make -j$(nproc) && make install && cd .. && rm -rf x264

# Build ffmpeg — no external codec deps, NVENC via dlopen at runtime
RUN git clone --depth 1 -b n8.0.1 https://github.com/FFmpeg/FFmpeg.git /ffmpeg
WORKDIR /ffmpeg
RUN PKG_CONFIG_PATH=/opt/x264/lib/pkgconfig ./configure \
        --prefix=/opt/ffmpeg \
        --enable-gpl \
        --enable-version3 \
        --enable-ffnvcodec \
        --enable-nvenc \
        --enable-nvdec \
        --enable-cuvid \
        --enable-openssl \
        --enable-protocol=rtsp,rtp,tcp,udp,file,pipe,data,https,http,crypto,tls \
        --enable-demuxer=rtsp,rtp,h264,aac,mp4,mov,mpegts,segment \
        --enable-muxer=segment,mp4,mpegts,rtp,rtsp,null \
        --enable-decoder=h264,hevc,av1,aac,mp3,pcm_alaw,pcm_mulaw \
        --enable-libx264 \
        --enable-encoder=h264_nvenc,hevc_nvenc,aac,libx264 \
        --extra-cflags="-I/opt/x264/include" \
        --extra-ldflags="-L/opt/x264/lib" \
        --enable-hwaccel=h264_nvdec,hevc_nvdec,av1_nvdec \
        --enable-filter=scale,format,fps,setpts,aresample,anull,null \
        --disable-doc \
        --disable-debug \
        --disable-shared \
        --enable-static \
    && make -j$(nproc) \
    && make install \
    && strip /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe

# Stage 2: Frigate with the updated ffmpeg binary
# Requires BuildKit and a named context for the vendor/frigate submodule:
#   docker buildx build -t frigate-nvenc:local \
#     -f build/frigate-nvenc/Dockerfile \
#     --build-context vendor-frigate=vendor/frigate \
#     build/frigate-nvenc/
FROM ghcr.io/blakeblackshear/frigate:stable-tensorrt

RUN mkdir -p /usr/lib/ffmpeg/8.0/bin
COPY --from=ffmpeg-builder /opt/ffmpeg/bin/ffmpeg /usr/lib/ffmpeg/8.0/bin/ffmpeg
COPY --from=ffmpeg-builder /opt/ffmpeg/bin/ffprobe /usr/lib/ffmpeg/8.0/bin/ffprobe

ENV DEFAULT_FFMPEG_VERSION=8.0
ENV INCLUDED_FFMPEG_VERSIONS=8.0:7.0:5.0

# Apply local patches from vendor/frigate (dolkens/v0.17.0-patches).
# See that branch for commit history explaining each change.
COPY --from=vendor-frigate frigate/stats/util.py /opt/frigate/frigate/stats/util.py
COPY --from=vendor-frigate frigate/util/services.py /opt/frigate/frigate/util/services.py
