#!/usr/bin/env bash
# 15_prep_os.sh
#
# Script to do misc OS prep.
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
sudo swapoff -a
sudo sed -i '/\sswap\s/d' /etc/fstab
sudo rm -f /swapfile
sudo systemctl mask swap.target
