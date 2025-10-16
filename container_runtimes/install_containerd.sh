#!/usr/bin/env bash
# install-containerd-debian.sh
# Installs containerd on Debian using Docker’s official repository.
# DISCLAIMER: Run at your own risk. The author assumes no liability for any damage or data loss.
#
#
# Assumptions: sudo is installed
#
# Tested on: 
#
# Debian 13.1
set -e

echo "[1/6] Updating system packages..."
sudo apt update -y
sudo apt install -y ca-certificates curl gnupg lsb-release

echo "[2/6] Adding Docker’s official GPG key..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "[3/6] Adding Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "[4/6] Updating repository index..."
sudo apt update -y

echo "[5/6] Installing containerd..."
sudo apt install -y containerd.io

echo "[6/6] Restarting and enabling containerd..."
sudo systemctl enable --now containerd

echo "Done. Version:"
containerd --version

echo "Verification:"
echo "  sudo systemctl status containerd --no-pager"
