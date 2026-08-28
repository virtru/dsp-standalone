#!/bin/bash
# Installs all prerequisite software for the Virtru DSP on macOS
# Requires Homebrew (https://brew.sh)

set -e

# ------------------------------------------------------------
# Homebrew
# ------------------------------------------------------------
echo "=== Checking Homebrew ==="
if ! command -v brew &> /dev/null; then
  echo "Homebrew not found. Installing..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for Apple Silicon
  if [[ "$(uname -m)" == "arm64" ]]; then
    # Preserve command substitution for future shells.
    # shellcheck disable=SC2016
    printf '%s\n' 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
else
  echo "Homebrew already installed — updating..."
  brew update
fi

# ------------------------------------------------------------
# Core dependencies
# ------------------------------------------------------------
echo "=== Installing core dependencies ==="
for pkg in curl wget git make python3 jq; do
  if ! command -v "$pkg" &> /dev/null; then
    brew install "$pkg"
  else
    echo "$pkg already installed — skipping."
  fi
done

# ------------------------------------------------------------
# Docker
# ------------------------------------------------------------
echo "=== Checking Docker ==="
if ! command -v docker &> /dev/null; then
  echo "Docker not found."
  echo ""
  echo "  OrbStack is RECOMMENDED for this stack on macOS."
  echo "  It provides native host networking and built-in Rosetta for linux/amd64 images."
  echo ""
  echo "  Install options (then re-run this script):"
  echo "    OrbStack (recommended):   https://orbstack.dev"
  echo "    Docker Desktop (note):    https://www.docker.com/products/docker-desktop"
  echo "      → If using Docker Desktop on Apple Silicon, enable Rosetta first:"
  echo "        Settings → General → Use Rosetta for x86/amd64 emulation on Apple Silicon"
  echo "    Rancher Desktop:          https://rancherdesktop.io"
  echo "    Colima (CLI):             brew install colima && colima start"
  exit 1
else
  echo "Docker already installed — $(docker --version)"
  # Warn Docker Desktop users on Apple Silicon about Rosetta
  if [[ "$(uname -m)" == "arm64" ]] && docker info 2>/dev/null | grep -q "Docker Desktop"; then
    echo ""
    echo "  WARNING: Docker Desktop detected on Apple Silicon."
    echo "  This stack uses linux/amd64 images. For best performance, enable Rosetta emulation:"
    echo "    Docker Desktop → Settings → General → Use Rosetta for x86/amd64 emulation on Apple Silicon"
    echo "  OrbStack (https://orbstack.dev) is recommended as an alternative — it handles this automatically."
    echo ""
  fi
fi

# ------------------------------------------------------------
# Docker Compose                                                                                                                                
# ------------------------------------------------------------
echo "=== Checking Docker Compose ==="
if ! docker compose version &> /dev/null; then
   echo "Docker Compose plugin not found — installing..."
   brew install docker-compose
   # Register as a Docker CLI plugin
   mkdir -p ~/.docker/cli-plugins
   ln -sfn "$(brew --prefix)/opt/docker-compose/bin/docker-compose" ~/.docker/cli-plugins/docker-compose
else
   echo "Docker Compose already installed — $(docker compose version)"
fi




# ------------------------------------------------------------
# Node.js (LTS) + nvm
# ------------------------------------------------------------
echo "=== Installing Node.js (LTS) ==="
if ! command -v node &> /dev/null; then
  brew install node
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
if ! command -v go &> /dev/null; then
  brew install go
fi

# ------------------------------------------------------------
# mkcert (Local TLS Certificates)
# ------------------------------------------------------------
echo "=== Installing mkcert ==="
if ! command -v mkcert &> /dev/null; then
  brew install mkcert
fi
mkcert -install

# ------------------------------------------------------------
# cosign (policy import/export signing)
# ------------------------------------------------------------
echo "=== Installing cosign ==="
if ! command -v cosign &> /dev/null; then
  brew install cosign
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
echo "1. If nvm was just installed, open a new terminal tab or run:"
echo "   source ~/.zshrc  (or ~/.bash_profile)"
echo "2. Start the DSP stack with the supported bundle:"
echo "   ./setup_and_validate.sh --skip-prereqs --bundle /path/to/virtru-dsp-bundle-2.0.6.6.tar.gz"
echo ""
echo "See README.md for the quick start and validation options."
echo ""
echo "===================================="
