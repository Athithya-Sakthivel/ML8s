#!/usr/bin/env bash
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.28.5+k3s1}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/config}"
PRELOAD_IMAGES="${PRELOAD_IMAGES:-ghcr.io/fluxcd/source-controller:v1.4.1 ghcr.io/fluxcd/kustomize-controller:v1.4.0 ghcr.io/fluxcd/helm-controller:v0.37.4 ghcr.io/fluxcd/notification-controller:v1.4.0 postgres:15-alpine}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info(){ printf "%b [INFO] %s%b\n" "${GREEN}" "$1" "${NC}"; }
log_warn(){ printf "%b [WARN] %s%b\n" "${YELLOW}" "$1" "${NC}"; }
log_error(){ printf "%b [ERROR] %s%b\n" "${RED}" "$1" "${NC}"; }

log_info "ASSUMPTIONS: sudo available; running on Linux; port 6443 accessible locally; script will install k3s binary and run k3s in standalone mode (not systemd); it may stop/uninstall an existing k3s service if version mismatch is detected"
log_info "CONTRACT: idempotent install of K3S_VERSION=${K3S_VERSION}; kubeconfig written to ${KUBECONFIG_PATH}; images listed in PRELOAD_IMAGES will be pulled into k3s containerd if possible"

if command -v k3s >/dev/null 2>&1; then
    CURRENT_VERSION="$(k3s --version 2>/dev/null | head -n1 | awk '{print $3}' || true)"
    if [ "${CURRENT_VERSION:-}" != "$K3S_VERSION" ]; then
        log_warn "Existing k3s ${CURRENT_VERSION:-unknown} detected, attempting safe uninstall"
        sudo /usr/local/bin/k3s-uninstall.sh || true
    else
        log_info "k3s ${K3S_VERSION} binary already present"
    fi
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet k3s; then
    log_warn "systemd-managed k3s is active; attempting to stop and uninstall to ensure standalone deterministic mode"
    sudo systemctl stop k3s || true
    sudo /usr/local/bin/k3s-uninstall.sh || true
fi

log_info "Installing k3s binary without starting systemd service"
curl -fsSL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_SKIP_START=true sh -s - --write-kubeconfig-mode 644 --disable traefik --disable servicelb

log_info "Starting k3s in standalone (non-systemd) mode"
sudo mkdir -p /var/log
sudo nohup k3s server --disable traefik --disable servicelb > /var/log/k3s-standalone.log 2>&1 &
echo $! | sudo tee /var/run/k3s-standalone.pid >/dev/null

log_info "Waiting for API readiness (timeout 180s)"
timeout=180
elapsed=0
interval=2
until sudo k3s kubectl get nodes >/dev/null 2>&1; do
    if [ $elapsed -ge $timeout ]; then
        log_error "Timeout waiting for k3s API. Showing last 200 log lines from /var/log/k3s-standalone.log"
        sudo tail -n 200 /var/log/k3s-standalone.log || true
        exit 1
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
done

log_info "k3s API is ready"

log_info "Configuring kubeconfig at ${KUBECONFIG_PATH}"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
sudo cp /etc/rancher/k3s/k3s.yaml "$KUBECONFIG_PATH"
sudo chown "$(id -u):$(id -g)" "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

log_info "Preloading images into k3s containerd runtime"
read -r -a IMAGES <<< "$PRELOAD_IMAGES"
for IMG in "${IMAGES[@]}"; do
    log_info "Processing image: ${IMG}"
    if sudo k3s ctr -n k8s.io images ls -q | grep -Fxq "${IMG}"; then
        log_info "Image already present: ${IMG}"
        continue
    fi
    if sudo k3s ctr -n k8s.io images pull "${IMG}"; then
        log_info "Successfully pulled: ${IMG}"
    else
        log_warn "Failed to pull image: ${IMG}"
    fi
done

log_info "Verifying cluster access using kubeconfig"
if kubectl --kubeconfig="$KUBECONFIG_PATH" get nodes >/dev/null 2>&1; then
    log_info "Cluster reachable"
else
    log_error "kubectl cannot reach the cluster; inspect /var/log/k3s-standalone.log"
    sudo tail -n 200 /var/log/k3s-standalone.log || true
    exit 1
fi

log_info "Cluster nodes:"
kubectl --kubeconfig="$KUBECONFIG_PATH" get nodes -o wide

log_info "Installed images in k3s runtime (first 200 lines):"
sudo k3s ctr -n k8s.io images ls | sed -n '1,200p' || true

log_info "k3s version: $(k3s --version | head -n1)"
log_info "Kubeconfig path: ${KUBECONFIG_PATH}"
log_info "k3s standalone logs: /var/log/k3s-standalone.log"
log_info "k3s standalone pidfile: /var/run/k3s-standalone.pid"
