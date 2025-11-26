#!/usr/bin/env bash
# init-k8s-control-plane.sh
# Initializes a Kubernetes control plane with kubeadm and applies Flannel CNI.
# DISCLAIMER: Run at your own risk. The author assumes no liability for any damage or data loss.
#
# Assumptions:
# - containerd installed and running
# - this script runs on the intended control-plane node
# - sudo available
#
# Tested on:
# - Debian 13.1 + containerd + kubeadm v1.34
set -e

POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

echo "[1/6] Initializing Kubernetes control plane..."
sudo kubeadm init \
  --pod-network-cidr="$POD_CIDR" \
  --service-cidr="$SERVICE_CIDR" \
  --cri-socket=unix:///var/run/containerd/containerd.sock

echo "[2/6] Setting up kubeconfig for current user..."
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

echo "[3/6] Verifying access to cluster..."
kubectl cluster-info

echo "[4/6] Applying Flannel CNI..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "[5/6] Listing system pods..."
kubectl get pods -n kube-system

echo "[6/6] Allowing control-plane scheduling (lab use only)..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "Control plane initialization complete."
echo "Verify cluster with:"
echo "  kubectl get nodes"
echo "Retrieve join info with:"
echo "  kubeadm token create --print-join-command"
