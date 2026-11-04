# syntax=docker/dockerfile:1
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
ARG BASE_IMAGE_URL="ghcr.io/ublue-os/bazzite-gnome"
ARG BASE_IMAGE_TAG="stable"

FROM ${BASE_IMAGE_URL}:${BASE_IMAGE_TAG}

# Run build script, verify bootc compliance
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# Verify final image and contents are bootc compliant
RUN bootc container lint
