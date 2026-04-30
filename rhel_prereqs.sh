#!/bin/bash
# Installs all prerequisite software for the Virtru DSP on Red Hat Enterprise Linux 8
#
# Supported platforms:
#   - Host OS:        RHEL 8 (amd64 or arm64)
#   - Containers:     linux/amd64  (DSP Docker images are amd64-only)
#   - Host arch:      amd64 (x86_64) or arm64 (aarch64)
#
# Note: The DSP Docker images are built for linux/amd64. Running on an arm64 RHEL
# host requires hardware-level amd64 emulation (e.g. QEMU), which is not recommended
# for production use and may impact performance.
#
# Note: RHEL 8 ships with Podman by default. This script installs Docker CE from
# the official Docker repository. podman-docker (if present) will be removed to
# avoid conflicts.

set +e  # do not exit on individual step failures — setup_and_validate.sh handles continuation

# ------------------------------------------------------------
# Architecture detection
#   HOST_ARCH  — the real CPU architecture; used for installing
#                native tools (Go, grpcurl, DSP binary)
#   CONTAINER_ARCH — always amd64; DSP Docker images are
#                    linux/amd64-only regardless of host CPU
# ------------------------------------------------------------
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64)        HOST_ARCH="amd64" ;;
  aarch64|arm64) HOST_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH_RAW"; exit 1 ;;
esac
CONTAINER_ARCH="amd64"

echo "=== Architecture: host=linux/${HOST_ARCH}  containers=linux/${CONTAINER_ARCH} ==="
if [[ "$HOST_ARCH" != "$CONTAINER_ARCH" ]]; then
  echo "    NOTE: Host is ${HOST_ARCH}. DSP Docker images are ${CONTAINER_ARCH}-only."
  echo "    Docker will use QEMU emulation — performance may be reduced."
fi

echo "=== Updating system packages ==="
sudo dnf update -y

# ------------------------------------------------------------
# EPEL repository (needed for some packages on RHEL 8)
# ------------------------------------------------------------
echo "=== Enabling EPEL repository ==="
if ! rpm -q epel-release &>/dev/null; then
  sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
  echo "EPEL enabled."
else
  echo "EPEL already enabled — skipping."
fi

echo "=== Installing core dependencies ==="
sudo dnf install -y \
  gcc \
  make \
  curl \
  wget \
  git \
  ca-certificates \
  gnupg2 \
  python3 \
  python3-pip \
  jq

# Development tools group (provides compilers, headers, etc.)
sudo dnf groupinstall -y "Development Tools" || true

# ------------------------------------------------------------
# Docker (runtime + compose)
# ------------------------------------------------------------
echo "=== Installing Docker and Docker Compose ==="

# Remove podman-docker shim if present — it conflicts with Docker CE
if rpm -q podman-docker &>/dev/null; then
  echo "Removing podman-docker shim to avoid conflicts with Docker CE..."
  sudo dnf remove -y podman-docker || true
fi

if ! command -v docker &> /dev/null; then
  # Remove any old conflicting packages
  sudo dnf remove -y docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-engine \
    podman runc || true

  # Add Docker CE repository for RHEL 8
  sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

  sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# ------------------------------------------------------------
# Docker Compose
# ------------------------------------------------------------
echo "=== Checking Docker Compose ==="
if ! docker compose version &> /dev/null; then
  echo "Docker Compose plugin not found — installing..."
  sudo dnf install -y docker-compose-plugin
else
  echo "Docker Compose already installed — $(docker compose version)"
fi

sudo systemctl enable --now docker
REAL_USER="${SUDO_USER:-$USER}"
sudo usermod -aG docker "$REAL_USER"
echo "Added $REAL_USER to the docker group — log out and back in for this to take effect."

# ------------------------------------------------------------
# Node.js (LTS) + npm + nvm
# ------------------------------------------------------------
echo "=== Installing Node.js (LTS) ==="
if ! command -v node &> /dev/null; then
  curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
  sudo dnf install -y nodejs
fi

echo "=== Installing nvm (Node Version Manager) ==="
if [ ! -d "$HOME/.nvm" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  nvm install --lts
fi

# ------------------------------------------------------------
# Go (Golang)
# ------------------------------------------------------------
echo "=== Installing Go (Golang) ==="
GO_VERSION="1.23.2"
if ! command -v go &> /dev/null; then
  GO_TAR="go${GO_VERSION}.linux-${HOST_ARCH}.tar.gz"
  wget -P /tmp "https://go.dev/dl/${GO_TAR}"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "/tmp/${GO_TAR}"
  rm "/tmp/${GO_TAR}"
  echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
  export PATH=$PATH:/usr/local/go/bin   # take effect in this session
  echo "Go installed: $(go version)"
fi

# ------------------------------------------------------------
# mkcert (Local TLS Certificates)
# ------------------------------------------------------------
echo "=== Installing mkcert ==="
# nss-tools provides certutil needed by mkcert for NSS database management
sudo dnf install -y nss-tools
if ! command -v mkcert &> /dev/null; then
  MKCERT_VERSION=$(curl -fsSL https://api.github.com/repos/FiloSottile/mkcert/releases/latest \
    | grep tag_name | cut -d'"' -f4)
  wget -P /tmp "https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-linux-${HOST_ARCH}"
  sudo mv "/tmp/mkcert-${MKCERT_VERSION}-linux-${HOST_ARCH}" /usr/local/bin/mkcert
  sudo chmod +x /usr/local/bin/mkcert
  echo "mkcert installed: $(mkcert --version)"
fi

# ------------------------------------------------------------
# cosign (policy import/export signing)
# ------------------------------------------------------------
echo "=== Installing cosign ==="
if ! command -v cosign &> /dev/null; then
  COSIGN_VERSION=$(curl -fsSL https://api.github.com/repos/sigstore/cosign/releases/latest | grep tag_name | cut -d'"' -f4)
  curl -fsSLo /tmp/cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${HOST_ARCH}"
  sudo mv /tmp/cosign /usr/local/bin/cosign
  sudo chmod +x /usr/local/bin/cosign
fi

# ------------------------------------------------------------
# grpcurl (gRPC command-line client)
# ------------------------------------------------------------
echo "=== Installing grpcurl ==="
# grpcurl uses x86_64 in release filenames where other tools use amd64
case "$HOST_ARCH" in
  amd64) GRPCURL_ARCH="x86_64" ;;
  arm64) GRPCURL_ARCH="arm64" ;;
esac
if ! command -v grpcurl &> /dev/null; then
  GRPCURL_VERSION=$(curl -fsSL https://api.github.com/repos/fullstorydev/grpcurl/releases/latest | grep tag_name | cut -d'"' -f4)
  curl -fsSLo /tmp/grpcurl.tar.gz "https://github.com/fullstorydev/grpcurl/releases/download/${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION#v}_linux_${GRPCURL_ARCH}.tar.gz"
  tar -xzf /tmp/grpcurl.tar.gz -C /tmp grpcurl
  sudo mv /tmp/grpcurl /usr/local/bin/grpcurl
  sudo chmod +x /usr/local/bin/grpcurl
  rm -f /tmp/grpcurl.tar.gz
  echo "grpcurl installed: $(grpcurl --version 2>&1)"
else
  echo "grpcurl already installed — $(grpcurl --version 2>&1)"
fi

# ------------------------------------------------------------
# Add local-dsp.virtru.com to /etc/hosts if not already present
# ------------------------------------------------------------
echo "=== Ensuring local-dsp.virtru.com is mapped in /etc/hosts ==="
if ! grep -q "local-dsp\.virtru\.com" /etc/hosts; then
  echo "127.0.0.1    local-dsp.virtru.com" | sudo tee -a /etc/hosts > /dev/null
  echo "Added entry: 127.0.0.1 local-dsp.virtru.com"
else
  echo "Entry already exists — skipping."
fi

# ------------------------------------------------------------
# DSP Bundle — unpack binary and grpcurl
# ------------------------------------------------------------
echo "=== DSP Bundle Setup ==="
echo ""
echo "  The Virtru DSP bundle is a .tar.gz file (e.g. virtru-dsp-bundle-X.X.X.tar.gz)."
echo ""

# Use the real user's home directory — $HOME resolves to /root when run with sudo
REAL_HOME=$(eval echo "~${SUDO_USER:-$USER}")

BUNDLE_TAR=""
while true; do
  read -rp "  Enter path to the Virtru DSP bundle .tar.gz file: " BUNDLE_TAR
  BUNDLE_TAR="${BUNDLE_TAR/#\~/$REAL_HOME}"
  if [[ -z "$BUNDLE_TAR" ]]; then
    echo "  Path cannot be empty."
    continue
  fi
  if [[ ! -f "$BUNDLE_TAR" ]]; then
    echo "  File not found: $BUNDLE_TAR"
    continue
  fi
  # Validate file type by magic bytes — faster and more reliable than tar -tzf on RHEL
  FILE_TYPE=$(file -b "$BUNDLE_TAR" 2>/dev/null)
  if ! echo "$FILE_TYPE" | grep -qi "gzip compressed"; then
    echo "  File does not appear to be a gzip archive: $BUNDLE_TAR"
    echo "  Detected type: ${FILE_TYPE:-unknown}"
    echo "  Expected a .tar.gz file (e.g. virtru-dsp-bundle-X.X.X.tar.gz)."
    continue
  fi
  break
done

echo "Unpacking bundle: $BUNDLE_TAR"
mkdir -p virtru-dsp-bundle
if ! tar -xvf "$BUNDLE_TAR" -C virtru-dsp-bundle/; then
  echo "ERROR: Failed to extract bundle: $BUNDLE_TAR"
  echo "Ensure the file is a valid .tar.gz archive and is not corrupted."
  exit 1
fi
cd virtru-dsp-bundle/

# Unpack DSP binary — uses HOST_ARCH (native binary for this machine)
DSP_TAR=$(ls tools/dsp/data-security-platform_*_linux_${HOST_ARCH}.tar.gz 2>/dev/null | head -1)
if [[ -z "$DSP_TAR" ]]; then
  echo "ERROR: Could not find DSP binary for linux/${HOST_ARCH} in tools/dsp/"
  exit 1
fi
echo "Unpacking DSP binary: $DSP_TAR"
tar -xvf "$DSP_TAR"

# Unpack grpcurl — bundle uses x86_64 naming (not amd64)
GRPCURL_TAR=$(ls tools/grpcurl/grpcurl_*_linux_${GRPCURL_ARCH}.tar.gz 2>/dev/null | head -1)
if [[ -z "$GRPCURL_TAR" ]]; then
  echo "ERROR: Could not find grpcurl for linux/${GRPCURL_ARCH} in tools/grpcurl/"
  exit 1
fi
echo "Unpacking grpcurl: $GRPCURL_TAR"
tar -xvf "$GRPCURL_TAR"

chmod +x ./grpcurl
echo "DSP bundle unpacked successfully."

cd ..

# ------------------------------------------------------------
# Post-install instructions
# ------------------------------------------------------------
echo "===================================="
echo "===================================="
echo "=== Prerequisite Setup Complete! ==="
echo ""
echo ""
echo "1. Reboot or log out/in for Docker group and ~/.bashrc changes to take effect."
echo "2. Continue to Step 1 in startupInstructions.md/README.md to start the COP services."
echo ""
echo "===================================="
