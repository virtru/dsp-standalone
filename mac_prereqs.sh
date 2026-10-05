#!/bin/bash
# Install the host tools used by setup and its default validation on macOS.

set -e

install_with_brew() {
  if ! command -v brew &> /dev/null; then
    echo "Homebrew is required to install missing tool: $1" >&2
    echo "Install Homebrew from https://brew.sh, then rerun setup." >&2
    exit 1
  fi
  brew install "$1"
}

echo "=== Checking setup tools ==="
for pkg in curl jq openssl mkcert cosign go; do
  if command -v "$pkg" &> /dev/null; then
    echo "$pkg already installed — skipping."
  else
    install_with_brew "$pkg"
  fi
done

echo "=== Checking Docker ==="
if ! command -v docker &> /dev/null; then
  echo "Docker not found. Start a Docker-compatible runtime, then rerun setup."
  echo "OrbStack: https://orbstack.dev"
  echo "Docker Desktop: https://www.docker.com/products/docker-desktop"
  exit 1
fi
echo "Docker already installed — $(docker --version)"
if [[ "$(uname -m)" == "arm64" ]] && docker info 2>/dev/null | grep -q "Docker Desktop"; then
  echo "WARNING: This stack uses linux/amd64 images. Enable Rosetta in Docker Desktop for better performance."
fi

echo "=== Checking Docker Compose ==="
if ! docker compose version &> /dev/null; then
  install_with_brew docker-compose
  mkdir -p "$HOME/.docker/cli-plugins"
  ln -sfn "$(brew --prefix)/opt/docker-compose/bin/docker-compose" "$HOME/.docker/cli-plugins/docker-compose"
fi
docker compose version

echo "=== Checking Docker Buildx ==="
if ! docker buildx version &> /dev/null; then
  if ! command -v brew &> /dev/null || [[ ! -x "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ]]; then
    install_with_brew docker-buildx
  fi
  mkdir -p "$HOME/.docker/cli-plugins"
  ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" "$HOME/.docker/cli-plugins/docker-buildx"
fi
docker buildx version

echo "=== Prerequisite setup complete ==="
