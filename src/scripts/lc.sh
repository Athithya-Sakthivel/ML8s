#!/usr/bin/env bash
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.28.5+k3s1}"
KUBECONFIG_PATH="${HOME}/.kube/config"
PRELOAD_IMAGES="${PRELOAD_IMAGES:-ghcr.io/fluxcd/source-controller:v1.4.1 ghcr.io/fluxcd/kustomize-controller:v1.4.0 ghcr.io/fluxcd/helm-controller:v0.37.4 ghcr.io/fluxcd/notification-controller:v1.4.0 postgres:15-alpine}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info(){ echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -eq 0 ]; then
    log_error "Do not run as root"
    exit 1
fi

if command -v k3s >/dev/null 2>&1; then
    CURRENT_VERSION=$(k3s --version | head -n1 | awk '{print $3}')
    if [ "$CURRENT_VERSION" != "$K3S_VERSION" ]; then
        log_warn "Existing k3s $CURRENT_VERSION detected, reinstalling $K3S_VERSION"
        sudo /usr/local/bin/k3s-uninstall.sh || true
    else
        log_info "k3s $K3S_VERSION already installed"
    fi
fi

log_info "Installing k3s $K3S_VERSION"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --disable servicelb

log_info "Waiting for API readiness"
timeout=120
elapsed=0
until sudo k3s kubectl get nodes >/dev/null 2>&1; do
    if [ $elapsed -ge $timeout ]; then
        log_error "Timeout waiting for k3s"
        exit 1
    fi
    sleep 2
    elapsed=$((elapsed+2))
done

log_info "Configuring kubeconfig"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
sudo cp /etc/rancher/k3s/k3s.yaml "$KUBECONFIG_PATH"
sudo chown $(id -u):$(id -g) "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

log_info "Preloading images into k3s containerd"
for IMG in ${PRELOAD_IMAGES}; do
    log_info "Checking image ${IMG}"
    if sudo k3s ctr -n k8s.io images ls | grep -q "${IMG}"; then
        log_info "Image already present: ${IMG}"
        continue
    fi
    log_info "Pulling ${IMG} into k3s runtime"
    if ! sudo k3s ctr -n k8s.io images pull "${IMG}"; then
        log_warn "Failed pulling ${IMG}"
    fi
done

log_info "Verifying cluster access"
kubectl get nodes >/dev/null

log_info "Cluster ready"
kubectl get nodes -o wide

log_info "Installed images in k3s runtime:"
sudo k3s ctr -n k8s.io images ls | sed -n '1,200p'

log_info "k3s version: $(k3s --version | head -n1)"
log_info "Kubeconfig: ${KUBECONFIG_PATH}"
