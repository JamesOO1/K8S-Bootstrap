#!/usr/bin/env bash
# 20_flannel_prep.sh
#
# Script to do mostly networking prep for flannel
# Returns 1 if an error was encounterd
# Returns 0 if successfully executed
# Process outlined here: 
#
# This script requires these commands:
# swapoff, sed, rm, sudos, systemctl



# 1. Disable Swap Space
echo "------------------------------------------------------"
echo "Disabling Swap Space"
echo "------------------------------------------------------"
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system >/dev/null

#net.bridge.bridge-nf-call-iptables = 1
#net.bridge.bridge-nf-call-ip6tables = 1
