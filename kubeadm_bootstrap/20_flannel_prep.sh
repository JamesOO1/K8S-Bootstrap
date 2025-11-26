#!/usr/bin/env bash
# 20_flannel_prep.sh
#
# Script to do mostly networking prep for flannel
# Returns 1 if an error was encounterd
# Returns 0 if successfully executed
# Process outlined here: 
#
# This script requires these commands:
# modprobe, sudo, tee, echo, sysctl



# 1. Enable br_netfilter, bridge-nf-call-iptables, and ip_forward
echo "------------------------------------------------------"
echo "Load br_netfilter module
echo "------------------------------------------------------"
echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf
sudo modprobe br_netfilter

#

echo "------------------------------------------------------"
echo "Enable ip_forward, iptable, and ip6tables.
echo "------------------------------------------------------"
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
echo "net.bridge.bridge-nf-call-iptables=1" | sudo tee -a /etc/sysctl.conf
echo "net.bridge.bridge-nf-call-ip6tables=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl --system


#net.bridge.bridge-nf-call-iptables = 1
#net.bridge.bridge-nf-call-ip6tables = 1
