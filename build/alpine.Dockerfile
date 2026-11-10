# syntax=docker/dockerfile:1
ARG ALPINE_IMAGE=alpine:3.24
FROM ${ALPINE_IMAGE} AS builder
RUN apk add --no-cache build-base clang git make pkgconf openssl-dev re2-dev zlib-dev openssl \
    ca-certificates python3

WORKDIR /build
COPY ci/ ci/
ARG V_REPOSITORY
ARG V_REVISION
ARG VC_REPOSITORY
ARG VC_REVISION
RUN sh ci/bootstrap-v.sh /opt/v

COPY Makefile v.mod Caddyfile ./
COPY src/ src/
COPY tests/ tests/
RUN test "$(uname -m)" = x86_64 \
    && make V=/opt/v/v VFLAGS='-prod -cc clang -gc boehm -d musl' \
    && make test V=/opt/v/v VTESTFLAGS='-cc clang -gc boehm -d musl -d use_bundled_libgc' \
    && ./vaddy validate --config Caddyfile \
    && python3 tests/integration.py ./vaddy \
    && mkdir /out \
    && cp vaddy /out/vaddy-alpine-x86_64

# Check the binary against the documented runtime packages, without build tools.
FROM ${ALPINE_IMAGE} AS runtime-check
RUN apk add --no-cache openssl re2 libstdc++ ca-certificates
COPY --from=builder /out/vaddy-alpine-x86_64 /usr/local/bin/vaddy
COPY Caddyfile /tmp/Caddyfile
RUN vaddy validate --config /tmp/Caddyfile

# BuildKit exports just the binary; no container runtime is needed to run it.
FROM scratch AS artifact
COPY --from=runtime-check /usr/local/bin/vaddy /vaddy-alpine-x86_64
