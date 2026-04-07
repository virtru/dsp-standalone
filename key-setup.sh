#!/bin/bash

# TLS certificate for Keycloak and DSP (port 18443 / 8080)
mkcert \
  -cert-file dsp-keys/local-dsp.virtru.com.pem \
  -key-file  dsp-keys/local-dsp.virtru.com.key.pem \
  local-dsp.virtru.com "*.local-dsp.virtru.com" localhost

# KAS RSA key pair
openssl req -x509 -nodes -newkey RSA:2048 -subj "/CN=kas" \
  -keyout dsp-keys/kas-private.pem -out dsp-keys/kas-cert.pem -days 365

# KAS EC key pair
openssl ecparam -name prime256v1 > dsp-keys/ecparams.tmp
openssl req -x509 -nodes -newkey ec:dsp-keys/ecparams.tmp -subj "/CN=kas" \
  -keyout dsp-keys/kas-ec-private.pem -out dsp-keys/kas-ec-cert.pem -days 365
rm dsp-keys/ecparams.tmp

# Policy import/export signing keys (requires cosign CLI)
mkdir -p dsp-keys/policyimportexport
(
  COSIGN_PASSWORD=$(openssl rand -base64 32)
  export COSIGN_PASSWORD
  cosign generate-key-pair \
    --output-key-prefix dsp-keys/policyimportexport/cosign
  printf '%s' "$COSIGN_PASSWORD" > dsp-keys/policyimportexport/cosign.pass
)

# Encrypted search key (32-byte hex value used by the SharePoint PEP - this is a dummy placeholder file)
echo writing search key to dsp-keys/encrypted-search.key
printf '%s' $(openssl rand -hex 32) > dsp-keys/encrypted-search.key
