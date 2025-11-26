#!/usr/bin/env bash
# 00_check__local_kubeadm_prerequsities.sh
#
# Script to check some prerequisities for installing kubeadm.
# Returns 1 if computer doesn't meet requirements
# Returns 0 if computer meets requirements
# Note: Most non-local requirements (network requirements) are out of scope of this script.
# KubeAdm Requirements outlined here: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
# 
# This script requires these commands:
# free, awk, echo, return, if/else/fi, grep, sort, cut, end, for/do/break/done


# 1: 2 GB or more of RAM per machine (any less will leave little room for your apps).
TOTAL_MEMORY=$(free -m | awk 'NR==2{print $2}')
if [[ "$TOTAL_MEMORY" -gt "2048" ]]; then
  echo "Memory is greater than 2048 MB. Successful"
else
  echo "Memory is less than 2048 MB. Failing check"
  return 1
fi

# 2: 2 CPUs or more for control plane machines.
AVAILABLE_CPU_CORES=$(grep "cpu cores" /proc/cpuinfo | sort -u | cut -d: -f2 | awk '{s+=$1} END {print s}')
if [[ "$AVAILABLE_CPU_CORES" -gt "2" ]]; then
  echo "More than 2 CPU cores available. Successful"
else
  echo "Less than 2 CPU cores available. Failing check"
  return 1
fi

LTS_KERNELS=("6.12" "6.6" "6.1" "5.15" "5.10" "5.4")
OS_VERSION=$(uname -r)
MATCH_FOUND=1
for LTS_KERNEL in "${LTS_KERNELS[@]}"; do
  if [[ "$OS_VERSION" == *"$LTS_KERNEL"* ]]; then
    echo "Current kernel appears to be part of $LTS_KERNEL"
    MATCH_FOUND=0
    break
  else
    echo "Current kernel is not $LTS_KERNEL"
  fi
done

return $MATCH_FOUND
