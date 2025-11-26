#!/usr/bin/env bash
# prepare_k8s_os.sh
# Prepares the OS for K8S
# DISCLAIMER: Run at your own risk. The author assumes no liability for any damage or data loss.
#
# Assumptions: sudo is installed
# Tested on: Debian 13.1

set -e

echo "[1/6] Disabling swap..." #Note: this is probably overkill
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
sudo systemctl daemon-reload

# See everything, not just active
systemctl --type=swap --all
systemctl list-unit-files --type=swap

# If a unit shows up, stop and mask it
sudo systemctl stop dev-*.swap 2>/dev/null || true
sudo systemctl mask dev-*.swap 2>/dev/null || true

# Belt-and-suspenders: block generic activation
sudo systemctl mask swap.target

# If zram is present, disable it
echo -e "[zram0]\nenabled = false" | sudo tee /etc/systemd/zram-generator.conf
sudo systemctl daemon-reload
sudo systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
sudo systemctl disable systemd-zram-setup@zram0.service 2>/dev/null || true

# Verify
cat /proc/swaps


echo "[2/6] Loading required kernel modules..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

echo "[3/6] Applying sysctl parameters for Kubernetes networking..."
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system >/dev/null

echo "[4/6] Ensuring directories for CNI exist..."
sudo mkdir -p /etc/cni/net.d /opt/cni/bin

echo "[5/6] Verifying kernel modules and sysctl settings..."
lsmod | grep -E 'br_netfilter|overlay' || echo "Warning: required modules not loaded"
sudo sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

echo "[6/6] Swap status:"
cat /proc/swaps || true
free -h

echo "System preparation complete."
echo "Next: run install_containerd.sh, then install_k8s_components.sh."
