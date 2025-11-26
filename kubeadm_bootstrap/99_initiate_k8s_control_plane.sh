#!/usr/bin/env bash
# 99_initiate_k8s_control_plane.sh
#
# Script to initiate the K8s control plane
# Returns 1 if an error was encounterd
# Returns 0 if successfully executed
# Process outlined here: 
#
# This script requires these commands:
# 

POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

# 1. Initiate the K8S Cluster
echo "------------------------------------------------------"
echo "Initiate the K8S Cluster"
echo "------------------------------------------------------"
sudo kubeadm init \
  --pod-network-cidr="$POD_CIDR" \
  --service-cidr="$SERVICE_CIDR" \
  --cri-socket=unix:///var/run/containerd/containerd.sock

# 2. Apply the Flannel Conf
echo "------------------------------------------------------"
echo "Apply the Flannel Conf"
echo "------------------------------------------------------"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
