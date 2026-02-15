#!/usr/bin/env bash

CLUSTER_NAME="${CLUSTER_NAME:-local}"
KIND_VERSION="${KIND_VERSION:-v0.29.0}"
LOCAL_BIN="${LOCAL_BIN:-$HOME/.local/bin}"

mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required"
    exit 1
  }
}

require curl
require docker

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon not running"
  exit 1
fi

OS="$(uname | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) ARCH="amd64" ;;
esac

# Install kind if missing
if ! command -v kind >/dev/null 2>&1; then
  echo "Installing kind ${KIND_VERSION}"
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" \
    -o "${LOCAL_BIN}/kind"
  chmod +x "${LOCAL_BIN}/kind"
fi

# Install kubectl if missing
if ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL_VERSION="$(curl -s https://dl.k8s.io/release/stable.txt)"
  echo "Installing kubectl ${KUBECTL_VERSION}"
  curl -fsSL -o "${LOCAL_BIN}/kubectl" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  chmod +x "${LOCAL_BIN}/kubectl"
fi

# Always delete existing cluster
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "Deleting existing cluster ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}"
fi

# Create single-node cluster
echo "Creating cluster ${CLUSTER_NAME}"
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF

# Wait for node readiness
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# Apply allow-all network policy (ingress + egress)
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

echo "Cluster ready"
kubectl get nodes -o wide


