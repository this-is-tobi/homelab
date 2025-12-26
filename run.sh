#!/bin/bash
#
# Homelab Management Script
# =========================
# This script provides a unified interface for managing the homelab infrastructure
# and GitOps-based Kubernetes deployments.
#
# Infrastructure (Ansible):
#   - Gateway setup (HAProxy, WireGuard, PiHole)
#   - K3s cluster deployment
#
# Applications (GitOps via ArgoCD):
#   - Core services (Longhorn, Cert-Manager, Vault, ArgoCD)
#   - Platform services (Keycloak, Gitea, Harbor, etc.)
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_PATH="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"

# Defaults
export ANSIBLE_CONFIG="$SCRIPT_PATH/ansible/ansible.cfg"
FETCH_KUBECONFIG="false"
PLAYBOOK=""
TAGS="all"
DECRYPT="false"
ENCRYPT="false"
UPDATE="false"
BOOTSTRAP="false"
APPLY_CORE=""
APPLY_PLATFORMS=""

# =============================================================================
# Helper Functions
# =============================================================================

log() {
  echo -e "${BLUE}[homelab]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[homelab]${NC} $*" >&2
}

error() {
  echo -e "${RED}[homelab]${NC} $*" >&2
}

success() {
  echo -e "${GREEN}[homelab]${NC} $*"
}

confirm() {
  local message="$1"
  echo -e "${YELLOW}[homelab]${NC} $message (Y/n)"
  read -r ANSWER
  if [[ "$ANSWER" =~ ^[Nn] ]]; then
    return 1
  fi
  return 0
}

# =============================================================================
# Help
# =============================================================================

print_help() {
  cat << 'EOF'

Homelab Management Script
=========================

This script manages homelab infrastructure (via Ansible) and Kubernetes
applications (via GitOps/ArgoCD).

USAGE:
  ./run.sh [OPTIONS]

INFRASTRUCTURE (Ansible):
  -p <playbook>   Run ansible playbook for infrastructure setup.
                  Example: ./run.sh -p ./ansible/install.yml

  -t <tags>       Tags to run with playbook, default is 'all'.
                  Multiple tags: -t 'gateway,k3s'
                  Available tags:
                    - gateway       : Setup gateway (HAProxy, WireGuard, PiHole)
                    - k3s           : Deploy K3s cluster
                    - k3s-deploy    : Deploy K3s only
                    - k3s-destroy   : Destroy K3s cluster
                    - os-upgrade    : Upgrade OS on all hosts

  -k              Fetch kubeconfig from cluster and configure local kubectl.
                  Kubeconfig saved to: ~/.kube/config.d/homelab

  -u              Update ansible galaxy collections before running playbook.

GITOPS (ArgoCD):
  -b              Bootstrap ArgoCD and core manager ApplicationSet.
                  This is the first step after K3s deployment.

  -c <instance>   Apply core services for an instance (e.g., 'homelab').
                  Deploys: Longhorn, Vault, Cert-Manager, etc.

  -s <instance>   Apply platform services for an instance (e.g., 'homelab').
                  Deploys: Keycloak, Gitea, Harbor, etc.

SECRETS (Sops):
  -d              Decrypt all *.enc.yaml files to *.dec.yaml in ./argo-cd

  -e              Encrypt all *.dec.yaml files to *.enc.yaml in ./argo-cd

GENERAL:
  -h              Print this help message.

EXAMPLES:

  # Setup infrastructure
  ./run.sh -p ./ansible/install.yml -t gateway    # Deploy gateway only
  ./run.sh -p ./ansible/install.yml -t k3s        # Deploy K3s cluster
  ./run.sh -p ./ansible/install.yml -u -k         # Full infra + fetch kubeconfig

  # Bootstrap GitOps
  ./run.sh -b                                      # Bootstrap ArgoCD

  # Deploy services via GitOps
  ./run.sh -c homelab                              # Apply core services
  ./run.sh -s homelab                              # Apply platform services

  # Secrets management
  ./run.sh -d                                      # Decrypt secrets
  ./run.sh -e                                      # Encrypt secrets

  # Destroy cluster
  ./run.sh -p ./ansible/install.yml -t k3s-destroy

EOF
}

# =============================================================================
# Sops Functions
# =============================================================================

decrypt_secrets() {
  log "Decrypting secrets with Sops..."
  find ./argo-cd -name '*.enc.yaml' -exec bash -c \
    'sops -d "$1" > "$(dirname "$1")/$(basename "$1" .enc.yaml).dec.yaml"' _ {} \;
  success "Secrets decrypted successfully"
}

encrypt_secrets() {
  log "Encrypting secrets with Sops..."
  find ./argo-cd -name '*.dec.yaml' -exec bash -c \
    'sops -e "$1" > "$(dirname "$1")/$(basename "$1" .dec.yaml).enc.yaml"' _ {} \;
  success "Secrets encrypted successfully"
}

# =============================================================================
# Ansible Functions
# =============================================================================

update_collections() {
  log "Updating Ansible collections..."
  ansible-galaxy collection install \
    -r "$SCRIPT_PATH/ansible/collections/requirements.yml" \
    --upgrade
  success "Ansible collections updated"
}

run_playbook() {
  local playbook="$1"
  local tags="$2"

  playbook="$(readlink -f "$playbook")"
  export ANSIBLE_CONFIG="$(dirname "$playbook")/ansible.cfg"

  log "Running Ansible playbook: $playbook"
  log "Tags: $tags"

  # Determine kubeconfig path
  local kubeconfig="${KUBECONFIG_PATH:-${KUBECONFIG:-$HOME/.kube/config}}"

  ansible-playbook "$playbook" \
    --tags "$tags" \
    -e "K8S_AUTH_KUBECONFIG=$kubeconfig"
}

fetch_kubeconfig() {
  log "Fetching kubeconfig from cluster..."

  local gateway_ip
  local master_ip
  local user

  gateway_ip=$(yq '[.gateway.hosts[][]][0]' "$SCRIPT_PATH/ansible/inventory/hosts.yml")
  master_ip=$(yq '[.k3s.children.masters.hosts[][]][0]' "$SCRIPT_PATH/ansible/inventory/hosts.yml")
  user=$(yq '.ansible_user' "$SCRIPT_PATH/ansible/inventory/group_vars/all.yml")

  mkdir -p "$HOME/.kube/config.d"
  scp "$user@$master_ip:/etc/rancher/k3s/k3s.yaml" "$HOME/.kube/config.d/homelab"

  # Update server address to gateway
  local cluster_kubeconfig
  cluster_kubeconfig="$(sed "s/127.0.0.1/$gateway_ip/g" "$HOME/.kube/config.d/homelab")"
  echo "$cluster_kubeconfig" > "$HOME/.kube/config.d/homelab"

  # Update main kubeconfig
  export CLUSTER_CERTIFICATE_AUTHORITY_DATA
  export CLUSTER_SERVER
  export USER_CLIENT_CERTIFICATE_DATA
  export USER_CLIENT_KEY_DATA

  CLUSTER_CERTIFICATE_AUTHORITY_DATA="$(yq '.clusters[0].cluster.certificate-authority-data' "$HOME/.kube/config.d/homelab")"
  CLUSTER_SERVER="$(yq '.clusters[0].cluster.server' "$HOME/.kube/config.d/homelab")"
  USER_CLIENT_CERTIFICATE_DATA="$(yq '.users[0].user.client-certificate-data' "$HOME/.kube/config.d/homelab")"
  USER_CLIENT_KEY_DATA="$(yq '.users[0].user.client-key-data' "$HOME/.kube/config.d/homelab")"

  yq -i '(.clusters[] | select(.name == "homelab") | .cluster.certificate-authority-data) = env(CLUSTER_CERTIFICATE_AUTHORITY_DATA)' ~/.kube/config
  yq -i '(.clusters[] | select(.name == "homelab") | .cluster.server) = env(CLUSTER_SERVER)' ~/.kube/config
  yq -i '(.users[] | select(.name == "homelab") | .user.client-certificate-data) = env(USER_CLIENT_CERTIFICATE_DATA)' ~/.kube/config
  yq -i '(.users[] | select(.name == "homelab") | .user.client-key-data) = env(USER_CLIENT_KEY_DATA)' ~/.kube/config

  success "Kubeconfig fetched and configured"
  log "Context 'homelab' is available. Use: kubectl config use-context homelab"
}

# =============================================================================
# GitOps Functions
# =============================================================================

check_kubectl() {
  if ! command -v kubectl &> /dev/null; then
    error "kubectl is not installed"
    exit 1
  fi

  local context
  context=$(kubectl config current-context 2>/dev/null || echo "none")
  if [[ "$context" == "none" ]]; then
    error "No kubectl context configured"
    exit 1
  fi

  if ! confirm "You are using kubectl context '$context', do you want to continue?"; then
    exit 1
  fi
}

check_helm() {
  if ! command -v helm &> /dev/null; then
    error "helm is not installed"
    exit 1
  fi
}

bootstrap_argocd() {
  log "Bootstrapping ArgoCD and core infrastructure..."

  check_kubectl
  check_helm

  # Create argocd namespace
  log "Creating argocd-system namespace..."
  kubectl create namespace argocd-system --dry-run=client -o yaml | kubectl apply -f -

  # Install ArgoCD using the homelab-core helm chart
  log "Installing ArgoCD..."
  helm dependency update "$SCRIPT_PATH/homelab-utils/helm"
  helm upgrade --install homelab-core "$SCRIPT_PATH/homelab-utils/helm" \
    --namespace argocd-system \
    --wait \
    --timeout 10m

  # Wait for ArgoCD to be ready
  log "Waiting for ArgoCD to be ready..."
  kubectl wait --for=condition=available deployment -l app.kubernetes.io/name=argocd-server \
    -n argocd-system --timeout=300s

  # Apply the core manager ApplicationSet
  log "Applying core manager ApplicationSet..."
  kubectl apply -f "$SCRIPT_PATH/argo-cd/core/manager.yaml"

  # Apply the platform manager ApplicationSet
  log "Applying platform manager ApplicationSet..."
  kubectl apply -f "$SCRIPT_PATH/argo-cd/platforms/manager.yaml"

  success "ArgoCD bootstrap complete!"
  log ""
  log "Next steps:"
  log "  1. Configure your instance in ./argo-cd/core/instances/<name>/"
  log "  2. Apply core services: ./run.sh -c <instance>"
  log "  3. Apply platform services: ./run.sh -s <instance>"
}

apply_core() {
  local instance="$1"
  local instance_dir="$SCRIPT_PATH/argo-cd/core/instances/$instance"

  if [[ ! -d "$instance_dir" ]]; then
    error "Instance '$instance' not found in $instance_dir"
    log "Available instances:"
    ls -1 "$SCRIPT_PATH/argo-cd/core/instances/" 2>/dev/null || echo "  (none)"
    exit 1
  fi

  check_kubectl

  log "Applying core services for instance: $instance"

  # The ApplicationSet will pick up the instance configuration automatically
  # Just need to ensure the manager is applied
  kubectl apply -f "$SCRIPT_PATH/argo-cd/core/manager.yaml"

  success "Core services configuration applied for '$instance'"
  log "ArgoCD will now sync the applications based on the instance configuration"
  log "Monitor progress: kubectl get applications -n argocd-system"
}

apply_platforms() {
  local instance="$1"
  local instance_dir="$SCRIPT_PATH/argo-cd/platforms/instances/$instance"

  if [[ ! -d "$instance_dir" ]]; then
    error "Instance '$instance' not found in $instance_dir"
    log "Available instances:"
    ls -1 "$SCRIPT_PATH/argo-cd/platforms/instances/" 2>/dev/null || echo "  (none)"
    exit 1
  fi

  check_kubectl

  log "Applying platform services for instance: $instance"

  # The ApplicationSet will pick up the instance configuration automatically
  kubectl apply -f "$SCRIPT_PATH/argo-cd/platforms/manager.yaml"

  success "Platform services configuration applied for '$instance'"
  log "ArgoCD will now sync the applications based on the instance configuration"
  log "Monitor progress: kubectl get applications -n argocd-system"
}

# =============================================================================
# Main
# =============================================================================

# Parse options
while getopts "hdekp:t:ubc:s:" flag; do
  case "${flag}" in
    d) DECRYPT="true" ;;
    e) ENCRYPT="true" ;;
    k) FETCH_KUBECONFIG="true" ;;
    p) PLAYBOOK="${OPTARG}" ;;
    t) TAGS="${OPTARG}" ;;
    u) UPDATE="true" ;;
    b) BOOTSTRAP="true" ;;
    c) APPLY_CORE="${OPTARG}" ;;
    s) APPLY_PLATFORMS="${OPTARG}" ;;
    h | *)
      print_help
      exit 0
      ;;
  esac
done

# Execute requested operations

# Sops operations
if [[ "$DECRYPT" == "true" ]]; then
  decrypt_secrets
fi

if [[ "$ENCRYPT" == "true" ]]; then
  encrypt_secrets
fi

# Ansible operations
if [[ "$UPDATE" == "true" ]]; then
  update_collections
fi

if [[ -n "$PLAYBOOK" ]]; then
  run_playbook "$PLAYBOOK" "$TAGS"
fi

if [[ "$FETCH_KUBECONFIG" == "true" ]]; then
  fetch_kubeconfig
fi

# GitOps operations
if [[ "$BOOTSTRAP" == "true" ]]; then
  bootstrap_argocd
fi

if [[ -n "$APPLY_CORE" ]]; then
  apply_core "$APPLY_CORE"
fi

if [[ -n "$APPLY_PLATFORMS" ]]; then
  apply_platforms "$APPLY_PLATFORMS"
fi

# Show help if no action was taken
if [[ "$DECRYPT" == "false" && "$ENCRYPT" == "false" && "$UPDATE" == "false" && \
      -z "$PLAYBOOK" && "$FETCH_KUBECONFIG" == "false" && "$BOOTSTRAP" == "false" && \
      -z "$APPLY_CORE" && -z "$APPLY_PLATFORMS" ]]; then
  print_help
fi
