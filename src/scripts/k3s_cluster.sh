#!/usr/bin/env bash
K3S_VERSION="v1.28.5+k3s1"
KUBECONFIG_PATH="${HOME}/.kube/config"

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

if [ "$EUID" -eq 0 ]; then
  log_error "Please do not run this script as root. It will use sudo when needed."
  exit 1
fi

if command -v k3s &> /dev/null; then
  CURRENT_VERSION=$(k3s --version | head -n1 | awk '{print $3}' || true)
  if [ "$CURRENT_VERSION" = "$K3S_VERSION" ]; then
    log_info "k3s $K3S_VERSION is already installed"
  else
    log_warn "k3s $CURRENT_VERSION is installed, but $K3S_VERSION is required"
    log_info "Uninstalling existing k3s..."
    sudo /usr/local/bin/k3s-uninstall.sh || true
  fi
fi

log_info "Installing k3s $K3S_VERSION..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable servicelb

log_info "Waiting for k3s to be ready..."
timeout=60
elapsed=0
while ! sudo k3s kubectl get nodes &> /dev/null; do
  if [ $elapsed -ge $timeout ]; then
    log_error "Timeout waiting for k3s to start"
    exit 1
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

log_info "Configuring kubectl access..."
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
sudo cp /etc/rancher/k3s/k3s.yaml "$KUBECONFIG_PATH"
sudo chown "$(id -u):$(id -g)" "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

log_info "Verifying cluster access..."
if ! kubectl get nodes &> /dev/null; then
  log_error "Failed to access cluster with kubectl"
  exit 1
fi

log_info "k3s cluster setup complete!"
echo ""
log_info "Cluster Information:"
kubectl get nodes
echo ""
log_info "k3s version: $(k3s --version | head -n1)"
log_info "Kubeconfig: $KUBECONFIG_PATH"
echo ""
log_info "Useful commands:"
echo "  - Check cluster status: kubectl get nodes"
echo "  - View all resources: kubectl get all -A"
echo "  - Stop k3s: sudo systemctl stop k3s"
echo "  - Start k3s: sudo systemctl start k3s"
echo "  - Uninstall k3s: /usr/local/bin/k3s-uninstall.sh"
