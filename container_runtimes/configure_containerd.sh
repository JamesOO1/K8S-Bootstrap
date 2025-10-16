#!/usr/bin/env bash
# configure_containerd.sh
# Generate CRI-enabled config for containerd with systemd cgroups.
# DISCLAIMER: Run at your own risk. No liability assumed.
#
# Assumptions: Sudo is installed
#
# Tested on: Debian 13.1
set -e

echo "[1/3] Stop services (safe if not running)..."
sudo systemctl stop kubelet || true
sudo systemctl stop containerd || true

echo "[2/3] Generate /etc/containerd/config.toml with SystemdCgroup=true..."
sudo mkdir -p /etc/containerd
sudo rm -f /etc/containerd/config.toml
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
# Ensure CRI plugin not disabled and use systemd cgroups
sudo sed -ri 's/^disabled_plugins = \[.*\]/# &/' /etc/containerd/config.toml
sudo sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

echo "[3/3] Restart containerd and kubelet..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl restart containerd
sudo systemctl start kubelet || true #Just in case if it's already installed

echo "containerd CRI configured."
