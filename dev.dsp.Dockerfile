# syntax=docker/dockerfile:1.6@sha256:ac85f380a63b13dfcefa89046420e1781752bab202122f8f50032edf31be0021
# Set your runtime image (override with --build-arg)
# DSP_IMAGE must be supplied at build time (the supported DSP 2.0.6.6 bundle
# provides localhost:5000/virtru/data-security-platform:v2.7.14).
# setup_and_validate.sh verifies that exact public-release tag in the registry.
ARG DSP_IMAGE

# ---------- prep stage: build CA bundle & stage files ----------
# --platform=$BUILDPLATFORM runs this stage natively on the build host (arm64 or amd64).
# Without it, platform: linux/amd64 on the service forces the prep stage to run as amd64,
# which causes "exec /bin/sh: exec format error" on arm64 Linux hosts without QEMU.
# The final DSP stage still targets linux/amd64 via the service's platform setting.
FROM --platform=$BUILDPLATFORM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40 AS prep
WORKDIR /work

# CA tools and trust store
# Rolling Alpine base: pin the image by digest (above), not apk package versions.
# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates && update-ca-certificates

# TLS materials
# (Only certificates belong in /usr/local/share/ca-certificates; keep private keys elsewhere.)
COPY ./dsp-keys/local-dsp.virtru.com.pem      /usr/local/share/ca-certificates/local-dsp.virtru.com.crt
COPY ./dsp-keys/local-dsp.virtru.com.key.pem  /work/dsp-keys/local-dsp.virtru.com.key.pem


# Merge our cert into the system bundle and stash it to copy later
RUN update-ca-certificates && cp /etc/ssl/certs/ca-certificates.crt /work/ca-certificates.crt

# KAS keys & app configs the runtime needs
COPY ./dsp-keys/kas-ec-cert.pem     /work/dsp-keys/kas-ec-cert.pem
COPY ./dsp-keys/kas-ec-private.pem  /work/dsp-keys/kas-ec-private.pem
COPY ./dsp-keys/kas-cert.pem        /work/dsp-keys/kas-cert.pem
COPY ./dsp-keys/kas-private.pem     /work/dsp-keys/kas-private.pem

COPY ./sample.keycloak.yaml         /work/samples/defaults/keycloak_data.yaml
COPY ./sample.federal_policy.yaml   /work/samples/defaults/federal_policy.yaml
COPY ./dsp.yaml                     /work/dsp.yaml

# quick checks (runs in prep stage which has /bin/sh)
RUN test -f /work/samples/defaults/keycloak_data.yaml \
 && test -f /work/samples/defaults/federal_policy.yaml \
 && test -f /work/dsp.yaml \
 && test -f /work/dsp-keys/kas-ec-cert.pem \
 && test -f /work/dsp-keys/kas-ec-private.pem \
 && test -f /work/dsp-keys/kas-cert.pem \
 && test -f /work/dsp-keys/kas-private.pem \
 && test -f /work/ca-certificates.crt

# ---------- final stage ----------
# DSP_IMAGE is supplied at build time with an explicit tag (see ARG above).
# hadolint ignore=DL3006
FROM ${DSP_IMAGE} AS dsp

# Install curl for Docker health checks
# Rolling/curated DSP base: pin the image, not apt/apk package versions.
# hadolint ignore=DL3008,DL3018
RUN { apt-get update -qq && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*; } 2>/dev/null || \
    apk add --no-cache curl 2>/dev/null || true

# Copy only what’s needed; avoid copying the entire prep filesystem.
COPY --from=prep /work/dsp-keys/           /dsp-keys/
COPY --from=prep /work/samples/            /samples/
COPY --from=prep /work/dsp.yaml            /dsp.yaml

# Provide CA bundle and point clients at it
COPY --from=prep /work/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

ENTRYPOINT ["/usr/bin/dsp"]
