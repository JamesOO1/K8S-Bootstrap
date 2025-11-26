#!/usr/bin/env bash
# install-kubernetes-tools-debian.sh
# Installs kubelet, kubeadm, and kubectl on Debian.
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
sudo apt install -y apt-transport-https ca-certificates curl gpg

echo "[2/6] Adding Kubernetes apt repository..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

echo "[3/6] Updating apt package index..."
sudo apt update -y

echo "[4/6] Installing kubelet, kubeadm, and kubectl..."
sudo apt install -y kubelet kubeadm kubectl

echo "[5/6] Holding Kubernetes packages at current version..."
sudo apt-mark hold kubelet kubeadm kubectl

echo "[6/6] Enabling kubelet service..."
sudo systemctl enable --now kubelet.service

echo "Installation complete."
echo "Verify with:"
echo "  kubeadm version"
echo "  kubectl version --client"
echo "  systemctl status kubelet"
