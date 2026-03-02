#!/usr/bin/env bash
#
# k8s-worker-bootstrap-rhel10.sh
# Idempotent script to prepare a RHEL 10 worker node for: kubeadm join
#
# Target:      RHEL 10 (or compatible: CentOS Stream 10, Rocky 10, Alma 10)
# Kubernetes:  1.31
# Runtime:     containerd
# CNI:         Cilium (agent deployed automatically by control plane)
#
# Usage:       sudo bash k8s-worker-bootstrap-rhel10.sh
# Idempotent:  Safe to run multiple times. Skips already-completed steps.
#
set -euo pipefail

# Ensure /usr/local/bin is in PATH
export PATH="/usr/local/bin:$PATH"

# ─── Configuration ────────────────────────────────────────────────────────────
KUBE_VERSION="1.31"
CRICTL_SOCKET="unix:///run/containerd/containerd.sock"

# ─── Colors / helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fatal() { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fatal "This script must be run as root (or via sudo)."

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

if grep -qE '^\s*[^#].*\sswap\s' /etc/fstab; then
    sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
    info "Swap entries commented out in /etc/fstab."
else
    info "/etc/fstab already clean of swap entries."
fi

systemctl mask --now "dev-zram"*.swap 2>/dev/null || true

# ─── 2. SELinux → permissive (idempotent) ────────────────────────────────────
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

# ─── 3. Firewall — worker node ports only (idempotent) ───────────────────────
info "Configuring firewall rules..."
if systemctl is-active --quiet firewalld; then
    # Kubelet API
    for port in 10250/tcp; do
        if ! firewall-cmd --query-port="$port" --permanent &>/dev/null; then
            firewall-cmd --add-port="$port" --permanent
        fi
    done
    # NodePort range
    for port in 30000-32767/tcp; do
        if ! firewall-cmd --query-port="$port" --permanent &>/dev/null; then
            firewall-cmd --add-port="$port" --permanent
        fi
    done
    # Cilium: VXLAN (8472/udp), health checks (4240/tcp), Hubble (4244/tcp)
    for port in 8472/udp 4240/tcp 4244/tcp; do
        if ! firewall-cmd --query-port="$port" --permanent &>/dev/null; then
            firewall-cmd --add-port="$port" --permanent
        fi
    done
    firewall-cmd --reload
    info "Firewall rules applied."
else
    warn "firewalld is not running. Ensure your firewall allows k8s worker ports."
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

DOCKER_REPO="/etc/yum.repos.d/docker-ce.repo"
if [[ ! -f "$DOCKER_REPO" ]]; then
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo || \
    fatal "Failed to add Docker repository."
    info "Docker (containerd) repo added."
else
    info "Docker repo already present."
fi

# These packages are required but come from RHEL BaseOS/AppStream, not Docker CE or EPEL.
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

containerd config default > "$CONTAINERD_CFG"

if grep -q 'SystemdCgroup = false' "$CONTAINERD_CFG"; then
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONTAINERD_CFG"
    info "containerd: SystemdCgroup enabled."
else
    info "containerd: SystemdCgroup already set."
fi

sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' "$CONTAINERD_CFG"
info "containerd: sandbox_image set to registry.k8s.io/pause:3.10"

systemctl daemon-reload
systemctl enable --now containerd
info "containerd service is running."

# ─── 7. Configure crictl ─────────────────────────────────────────────────────
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

dnf versionlock add kubelet kubeadm kubectl 2>/dev/null || \
    dnf mark install kubelet kubeadm kubectl 2>/dev/null || \
    warn "Could not version-lock k8s packages. Consider installing dnf-plugin-versionlock."

systemctl enable kubelet
info "kubelet enabled (it will start after kubeadm join)."

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
info "Worker node bootstrap complete!"
echo ""
info "To join this node to the cluster, run the join command from your"
info "control plane's kubeadm init output:"
echo ""
echo "  sudo kubeadm join <CONTROL_PLANE_IP>:6443 --token <TOKEN> \\"
echo "       --discovery-token-ca-cert-hash sha256:<HASH>"
echo ""
info "If you no longer have the join command, generate a new token on"
info "the control plane with:"
echo ""
echo "  kubeadm token create --print-join-command"
echo ""
echo "════════════════════════════════════════════════════════════════════"
