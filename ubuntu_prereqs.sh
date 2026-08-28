#!/bin/bash
# Installs all prerequisite software for the Virtru DSP on Ubuntu 24.04 LTS
#
# Configured platforms:
#   - Host OS:        Ubuntu 24.04 LTS (amd64 or arm64)
#   - Containers:     linux/amd64  (DSP Docker images are amd64-only)
#   - Validation:     amd64; arm64 is experimental and uses emulation
#
# The stack is for local development only. Running on an arm64 Ubuntu host
# requires amd64 emulation (for example, QEMU) and may reduce performance.

set +e  # do not exit on individual step failures — setup_and_validate.sh handles continuation

if [[ $EUID -eq 0 ]]; then
  echo "Do not run ubuntu_prereqs.sh with sudo or as root. Run it as your normal user; the script invokes sudo only for system-level changes." >&2
  exit 1
fi

# ------------------------------------------------------------
# Architecture detection
#   HOST_ARCH  — the real CPU architecture; used for installing native tools
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
sudo apt update -y && sudo apt upgrade -y

#echo "=== Installing packages for Virtualbox ==="
#sudo apt install -y \
#  open-vm-tools-desktop \
#  virtualbox-guest-additions-iso \
#  virtualbox-ext-pack

echo "=== Installing core dependencies ==="
sudo apt install -y \
  build-essential \
  curl \
  wget \
  git \
  make \
  ca-certificates \
  apt-transport-https \
  gnupg \
  lsb-release \
  software-properties-common \
  python3 \
  python3-pip

# ------------------------------------------------------------
# Docker (runtime + compose)
# ------------------------------------------------------------
echo "=== Installing Docker and Docker Compose ==="
if ! command -v docker &> /dev/null; then
  sudo apt remove -y docker docker-engine docker.io containerd runc || true
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update -y
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# ------------------------------------------------------------
# Docker Compose
# ------------------------------------------------------------
echo "=== Checking Docker Compose ==="
if ! docker compose version &> /dev/null; then
  echo "Docker Compose plugin not found — installing..."
  sudo apt update -y
  sudo apt install -y docker-compose-plugin
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
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt install -y nodejs
fi

echo "=== Installing nvm (Node Version Manager) ==="
if [ ! -d "$HOME/.nvm" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # nvm is downloaded at runtime.
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
  fi
  nvm install --lts
fi

# ------------------------------------------------------------
# Go (Golang)
# ------------------------------------------------------------
echo "=== Installing Go (Golang) ==="
GO_VERSION="1.25.13"
if ! command -v go &> /dev/null; then
  GO_TAR="go${GO_VERSION}.linux-${HOST_ARCH}.tar.gz"
  wget -P /tmp "https://go.dev/dl/${GO_TAR}"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "/tmp/${GO_TAR}"
  rm "/tmp/${GO_TAR}"
  # Preserve PATH expansion for future shells.
  # shellcheck disable=SC2016
  printf '%s\n' 'export PATH=$PATH:/usr/local/go/bin' >> "$HOME/.bashrc"
  export PATH=$PATH:/usr/local/go/bin   # take effect in this session
  echo "Go installed: $(go version)"
fi


# ------------------------------------------------------------
# mkcert (Local TLS Certificates)
# ------------------------------------------------------------
echo "=== Installing mkcert ==="
sudo apt install -y libnss3-tools
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
# Post-install instructions
# ------------------------------------------------------------
echo "===================================="
echo "=== Prerequisite Setup Complete! ==="
echo ""
echo "1. Run 'newgrp docker', or log out and back in, so Docker group membership takes effect."
echo "2. Start the DSP stack with the supported bundle:"
echo "   ./setup_and_validate.sh --skip-prereqs --bundle /path/to/virtru-dsp-bundle-2.0.6.6.tar.gz"
echo ""
echo "See README.md for the quick start and validation options."
echo ""
echo "===================================="
