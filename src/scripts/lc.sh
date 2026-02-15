#!/usr/bin/env bash

CLUSTER_NAME="${CLUSTER_NAME:-ml8s}"
KIND_VERSION="${KIND_VERSION:-v0.29.0}"
K8S_NODE_IMAGE="${K8S_NODE_IMAGE:-kindest/node:v1.33.1}"
LOCAL_BIN="${LOCAL_BIN:-$HOME/.local/bin}"

mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"

log() { printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    log "fatal: $1 is required"
    exit 1
  }
}

require curl
require docker

docker info >/dev/null 2>&1 || {
  log "fatal: docker daemon not running"
  exit 1
}

OS="$(uname | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) ARCH="amd64" ;;
esac

if ! command -v kind >/dev/null 2>&1; then
  log "installing kind ${KIND_VERSION}"
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" -o "${LOCAL_BIN}/kind"
  chmod +x "${LOCAL_BIN}/kind"
fi

if ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL_VERSION="$(curl -s https://dl.k8s.io/release/stable.txt)"
  log "installing kubectl ${KUBECTL_VERSION}"
  curl -fsSL -o "${LOCAL_BIN}/kubectl" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  chmod +x "${LOCAL_BIN}/kubectl"
fi

if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  log "deleting existing cluster ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}"
fi

log "pulling node image ${K8S_NODE_IMAGE}"
docker pull "${K8S_NODE_IMAGE}"

log "creating cluster ${CLUSTER_NAME}"
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --image "${K8S_NODE_IMAGE}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF

log "waiting for node readiness"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

FLUX_IMAGES=(
  "ghcr.io/fluxcd/source-controller:v1.4.1"
  "ghcr.io/fluxcd/kustomize-controller:v1.4.0"
  "ghcr.io/fluxcd/helm-controller:v0.37.4"
  "ghcr.io/fluxcd/notification-controller:v1.4.0"
)

for img in "${FLUX_IMAGES[@]}"; do
  log "pre-pulling ${img}"
  docker pull "${img}"
  log "loading ${img} into kind"
  kind load docker-image "${img}" --name "${CLUSTER_NAME}"
done

log "applying allow-all network policy"
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - {}
  egress:
  - {}
EOF

log "cluster ready"
kubectl get nodes -o wide
