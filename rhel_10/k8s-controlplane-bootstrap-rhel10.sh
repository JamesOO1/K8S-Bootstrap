#!/usr/bin/env bash
#
# k8s-controlplane-bootstrap-rhel10.sh
# Idempotent script to prepare a RHEL 10 node for: kubeadm init
#
# Target:      RHEL 10 (or compatible: CentOS Stream 10, Rocky 10, Alma 10)
# Kubernetes:  1.31
# Runtime:     containerd
# CNI:         Cilium (installed post-init; pod CIDR configured here)
# Pod CIDR:    172.16.0.0/16
#
# Usage:       sudo bash k8s-bootstrap-rhel10.sh
# Idempotent:  Safe to run multiple times. Skips already-completed steps.
#
set -euo pipefail

# Ensure /usr/local/bin is in PATH (needed for cilium CLI and other tools installed there)
export PATH="/usr/local/bin:$PATH"

# ─── Configuration ────────────────────────────────────────────────────────────
KUBE_VERSION="1.31"
KUBE_PACKAGE_VERSION="1.31.*"
POD_CIDR="172.16.0.0/16"
SERVICE_CIDR="10.96.0.0/12"          # k8s default; does NOT overlap your 10.x if it's host-only
CONTAINERD_VERSION=""                 # empty = latest from repo
CRICTL_SOCKET="unix:///run/containerd/containerd.sock"

# ─── Colors / helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fatal() { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fatal "This script must be run as root (or via sudo)."

# Validate OS — require RHEL/CentOS-Stream/Rocky/Alma major version 10
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID%%.*}"
    case "$OS_ID" in
        rhel|centos|rocky|almalinux) ;;
        *) fatal "Unsupported OS: $OS_ID. This script targets RHEL 10 and compatible distros." ;;
    esac
    [[ "$OS_VERSION" == "10" ]] || fatal "Unsupported OS version: $VERSION_ID. This script requires major version 10 (detected: $OS_VERSION)."
    info "Detected OS: $PRETTY_NAME"
else
    fatal "/etc/os-release not found. Cannot determine OS."
fi

# Architecture check
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  REPO_ARCH="x86_64" ;;
    aarch64) REPO_ARCH="aarch64" ;;
    *) fatal "Unsupported architecture: $ARCH" ;;
esac
info "Architecture: $ARCH"

# ─── 1. Disable swap (idempotent) ────────────────────────────────────────────
info "Ensuring swap is disabled..."
if swapon --show | grep -q .; then
    swapoff -a
    info "Swap disabled (runtime)."
else
    info "Swap already off."
fi

# Persist: comment out swap entries in fstab
if grep -qE '^\s*[^#].*\sswap\s' /etc/fstab; then
    sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
    info "Swap entries commented out in /etc/fstab."
else
    info "/etc/fstab already clean of swap entries."
fi

# Also mask any swap zram units
systemctl mask --now "dev-zram"*.swap 2>/dev/null || true

# ─── 2. SELinux → permissive (idempotent) ────────────────────────────────────
# Cilium and many k8s components need permissive (or custom policies).
# Switch to permissive; you can tighten later with targeted policies.
info "Checking SELinux..."
if command -v getenforce &>/dev/null; then
    current_se=$(getenforce)
    if [[ "$current_se" == "Enforcing" ]]; then
        setenforce 0
        info "SELinux set to Permissive (runtime)."
    fi
    if grep -q '^SELINUX=enforcing' /etc/selinux/config 2>/dev/null; then
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        info "SELinux config updated to permissive."
    else
        info "SELinux config already non-enforcing."
    fi
else
    info "SELinux tools not found; skipping."
fi

# ─── 3. Firewall — open required ports (idempotent) ──────────────────────────
info "Configuring firewall rules..."
if systemctl is-active --quiet firewalld; then
    # Control plane ports
    for port in 6443/tcp 2379-2380/tcp 10250/tcp 10259/tcp 10257/tcp; do
        if ! firewall-cmd --query-port="$port" --permanent &>/dev/null; then
            firewall-cmd --add-port="$port" --permanent
        fi
    done
    # Worker node ports (NodePort range + kubelet)
    for port in 30000-32767/tcp; do
        if ! firewall-cmd --query-port="$port" --permanent &>/dev/null; then
            firewall-cmd --add-port="$port" --permanent
        fi
    done
    # Cilium-specific: VXLAN (8472/udp), health checks (4240/tcp), Hubble (4244/tcp)
    for port in 8472/udp 4240/tcp 4244/tcp; do
        if ! firewall-cmd --query-port="$port" --permanent &>/dev/null; then
            firewall-cmd --add-port="$port" --permanent
        fi
    done
    firewall-cmd --reload
    info "Firewall rules applied."
else
    warn "firewalld is not running. Ensure your firewall allows k8s ports."
fi

# ─── 4. Kernel modules (idempotent) ──────────────────────────────────────────
info "Ensuring required kernel modules..."

MODULES_CONF="/etc/modules-load.d/k8s.conf"
REQUIRED_MODULES=(overlay br_netfilter)

if [[ ! -f "$MODULES_CONF" ]]; then
    printf '%s\n' "${REQUIRED_MODULES[@]}" > "$MODULES_CONF"
    info "Created $MODULES_CONF"
else
    info "$MODULES_CONF already exists."
fi

for mod in "${REQUIRED_MODULES[@]}"; do
    if ! lsmod | grep -qw "$mod"; then
        modprobe "$mod"
        info "Loaded module: $mod"
    else
        info "Module already loaded: $mod"
    fi
done

# ─── 5. Sysctl parameters (idempotent) ───────────────────────────────────────
info "Configuring sysctl for k8s networking..."

SYSCTL_CONF="/etc/sysctl.d/99-k8s.conf"
cat > "$SYSCTL_CONF" <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system &>/dev/null
info "sysctl parameters applied."

# ─── 6. Install containerd (idempotent) ──────────────────────────────────────
info "Setting up containerd..."

# Add Docker repo for containerd (official source for containerd packages on RHEL)
DOCKER_REPO="/etc/yum.repos.d/docker-ce.repo"
if [[ ! -f "$DOCKER_REPO" ]]; then
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo || \
    fatal "Failed to add Docker repository."
    info "Docker (containerd) repo added."
else
    info "Docker repo already present."
fi

# These packages are required but come from RHEL BaseOS/AppStream, not Docker CE or EPEL.
# The script checks for them and gives a clear error if they're unavailable.
REQUIRED_BASE_PKGS=(container-selinux conntrack-tools iproute-tc)
MISSING_PKGS=()

for pkg in "${REQUIRED_BASE_PKGS[@]}"; do
    if ! rpm -q "$pkg" &>/dev/null; then
        if ! dnf list --available "$pkg" &>/dev/null 2>&1; then
            MISSING_PKGS+=("$pkg")
        fi
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    fatal "The following packages are required but not available in any enabled repo:
       ${MISSING_PKGS[*]}

       These are provided by the RHEL BaseOS/AppStream repositories, not by EPEL or Docker CE.
       EPEL is a supplementary repo that requires the base RHEL repos to be present.

       To fix this, either:
         1. Register the system with subscription-manager and enable the base repos:
              subscription-manager register
              subscription-manager attach
         2. Or, if no Red Hat subscription is available, add CentOS Stream 10 BaseOS + AppStream repos.

       Then re-run this script."
fi

for pkg in "${REQUIRED_BASE_PKGS[@]}"; do
    if ! rpm -q "$pkg" &>/dev/null; then
        dnf install -y "$pkg" || fatal "Failed to install $pkg."
        info "$pkg installed."
    else
        info "$pkg already installed."
    fi
done

if ! rpm -q containerd.io &>/dev/null; then
    dnf install -y containerd.io
    info "containerd installed."
else
    info "containerd already installed."
fi

# Generate default config and enable SystemdCgroup
CONTAINERD_CFG="/etc/containerd/config.toml"
mkdir -p /etc/containerd

# Always regenerate config to ensure correctness (idempotent by nature)
containerd config default > "$CONTAINERD_CFG"

# Enable systemd cgroup driver (required for k8s 1.31+)
if grep -q 'SystemdCgroup = false' "$CONTAINERD_CFG"; then
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONTAINERD_CFG"
    info "containerd: SystemdCgroup enabled."
else
    info "containerd: SystemdCgroup already set."
fi

# Set the sandbox (pause) image to match what kubeadm expects
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' "$CONTAINERD_CFG"
info "containerd: sandbox_image set to registry.k8s.io/pause:3.10"

systemctl daemon-reload
systemctl enable --now containerd
info "containerd service is running."

# ─── 7. Install crictl (configure socket) ────────────────────────────────────
info "Configuring crictl..."
CRICTL_CONF="/etc/crictl.yaml"
cat > "$CRICTL_CONF" <<EOF
runtime-endpoint: $CRICTL_SOCKET
image-endpoint: $CRICTL_SOCKET
timeout: 10
EOF
info "crictl configured."

# ─── 8. Install kubeadm, kubelet, kubectl (idempotent) ───────────────────────
info "Setting up Kubernetes $KUBE_VERSION repo..."

KUBE_REPO="/etc/yum.repos.d/kubernetes.repo"
cat > "$KUBE_REPO" <<EOF
[kubernetes]
name=Kubernetes $KUBE_VERSION
baseurl=https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/rpm/repodata/repomd.xml.key
EOF
info "Kubernetes repo configured."

for pkg in kubelet kubeadm kubectl; do
    if ! rpm -q "$pkg" &>/dev/null; then
        dnf install -y "$pkg"
        info "$pkg installed."
    else
        info "$pkg already installed."
    fi
done

# Pin kubernetes packages to prevent unintended upgrades
dnf versionlock add kubelet kubeadm kubectl 2>/dev/null || \
    dnf mark install kubelet kubeadm kubectl 2>/dev/null || \
    warn "Could not version-lock k8s packages. Consider installing dnf-plugin-versionlock."

systemctl enable kubelet
info "kubelet enabled (it will start after kubeadm init)."

# ─── 9. Install Cilium CLI (idempotent) ──────────────────────────────────────
info "Checking Cilium CLI..."
if command -v cilium &>/dev/null; then
    info "Cilium CLI already installed: $(cilium version --client 2>/dev/null || echo 'unknown version')"
else
    info "Installing Cilium CLI..."
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    if [[ -z "$CILIUM_CLI_VERSION" ]]; then
        warn "Could not determine latest Cilium CLI version. Skipping install."
        warn "You can install it manually: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/"
    else
        case "$ARCH" in
            x86_64)  CLI_ARCH="amd64" ;;
            aarch64) CLI_ARCH="arm64" ;;
        esac
        curl -L --fail --remote-name-all \
            "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}" && \
        sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum" && \
        tar xzvf "cilium-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin cilium && \
        rm -f "cilium-linux-${CLI_ARCH}.tar.gz" "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum" && \
        info "Cilium CLI installed: $(cilium version --client)" || \
        warn "Cilium CLI installation failed. You can install it manually later."
    fi
fi

# ─── 9. Pre-pull images (idempotent — skips already-pulled) ──────────────────
info "Pre-pulling kubeadm images (this may take a few minutes)..."
kubeadm config images pull --kubernetes-version "$(kubeadm version -o short 2>/dev/null | sed 's/^v//')" 2>/dev/null || \
    kubeadm config images pull || \
    warn "Image pre-pull failed. kubeadm init will pull them on demand."

# ─── 10. Generate kubeadm config (idempotent) ────────────────────────────────
info "Writing kubeadm init config..."

KUBEADM_CFG="/etc/kubernetes/kubeadm-config.yaml"
mkdir -p /etc/kubernetes

cat > "$KUBEADM_CFG" <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: $CRICTL_SOCKET
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "$(kubeadm version -o short)"
networking:
  podSubnet: "$POD_CIDR"
  serviceSubnet: "$SERVICE_CIDR"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

info "kubeadm config written to $KUBEADM_CFG"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
info "Bootstrap complete! To initialize the cluster, run:"
echo ""
echo "  sudo kubeadm init --config=$KUBEADM_CFG"
echo ""
info "After init, install Cilium CLI and deploy the CNI:"
echo ""
echo "  export KUBECONFIG=/etc/kubernetes/admin.conf"
echo "  cilium install --set ipam.operator.clusterPoolIPv4PodCIDRList=$POD_CIDR"
echo ""
echo "════════════════════════════════════════════════════════════════════"
