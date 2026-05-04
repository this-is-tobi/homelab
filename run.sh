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
BOOTSTRAP_INSTANCE=""
YES="false"

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
  if [[ "$YES" == "true" ]]; then
    return 0
  fi
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
                    - dist-upgrade  : Debian major version upgrade (e.g. bookworm→trixie)

  -k              Fetch kubeconfig from cluster and configure local kubectl.
                  Kubeconfig saved to: ~/.kube/config.d/homelab

  -u              Update ansible galaxy collections before running playbook.

GITOPS (ArgoCD):
  -b <instance>   Bootstrap (or upgrade) the ohmlab release for the given
                  instance. Installs core ArgoCD + the root `manager`
                  ApplicationSet + the `admin-core` / `admin-tenant`
                  AppProjects. The manager then discovers every instance under:
                    ./argo-cd/instances/*/
                  and renders one Application per instance pointing at the
                  `instance-manager` chart (which fans out into per-scope
                  AppSets reading `core.yaml` and `tenant.yaml`).
                  Per-app values are read from:
                    ./argo-cd/instances/<instance>/values/{core,tenant}/<app>.yaml
                  Example: ./run.sh -b homelab

                  An optional admin password may be provided via the
                  ARGOCD_ADMIN_PASSWORD environment variable. The script will
                  bcrypt-hash it locally (requires `htpasswd` from
                  apache2-utils, or `python3` with bcrypt) and inject it into
                  the chart.
                  If unset, the ArgoCD chart auto-generates an admin password
                  and stores it in the `argocd-initial-admin-secret` Secret;
                  the script will print it at the end of the bootstrap.

SECRETS (Sops):
  -d              Decrypt all *.enc.yaml files to *.dec.yaml in ./argo-cd

  -e              Encrypt all *.dec.yaml files to *.enc.yaml in ./argo-cd

GENERAL:
  -y              Skip all confirmation prompts (non-interactive mode).

  -h              Print this help message.

EXAMPLES:

  # Setup infrastructure
  ./run.sh -p ./ansible/install.yml -t gateway    # Deploy gateway only
  ./run.sh -p ./ansible/install.yml -t k3s        # Deploy K3s cluster
  ./run.sh -p ./ansible/install.yml -u -k         # Full infra + fetch kubeconfig

  # Bootstrap GitOps
  ./run.sh -b homelab                              # Bootstrap homelab instance

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

# Bcrypt-hash a plain string using whatever's available locally.
# Echoes the hash on stdout; non-zero exit on failure.
bcrypt_hash() {
  local plain="$1"
  if command -v htpasswd &> /dev/null; then
    htpasswd -nbBC 10 "" "$plain" | tr -d ':\n' | sed 's/$2y/$2a/'
  elif command -v python3 &> /dev/null && python3 -c 'import bcrypt' &> /dev/null; then
    python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt(10)).decode())' "$plain"
  else
    error "Cannot bcrypt-hash password: install 'htpasswd' (apache2-utils) or 'python3-bcrypt'."
    return 1
  fi
}

# Print the auto-generated initial admin password (if the secret exists).
print_initial_admin_password() {
  local secret
  if ! secret=$(kubectl -n argocd-system get secret argocd-initial-admin-secret \
                  -o jsonpath='{.data.password}' 2>/dev/null); then
    return 0
  fi
  if [[ -z "$secret" ]]; then
    return 0
  fi
  log ""
  log "ArgoCD admin password (auto-generated):"
  log "  user:     admin"
  log "  password: $(echo "$secret" | base64 -d)"
  warn "Store this password and delete the secret once rotated:"
  warn "  kubectl -n argocd-system delete secret argocd-initial-admin-secret"
}

bootstrap_instance() {
  local instance="$1"
  local values_file="$SCRIPT_PATH/argo-cd/instances/$instance/values/core/ohmlab.yaml"
  local instance_dir="$SCRIPT_PATH/argo-cd/instances/$instance"

  # Folders prefixed with `_` are templates (e.g. `_example`) and are excluded
  # by the root manager AppSet. Refuse to bootstrap them.
  if [[ "$instance" == _* ]]; then
    error "Instance '$instance' starts with '_' and is treated as a template."
    error "Copy it to a real name first:  cp -r argo-cd/instances/$instance argo-cd/instances/<name>"
    exit 1
  fi

  if [[ ! -d "$instance_dir" ]]; then
    error "Instance '$instance' not found: $instance_dir"
    log "Available instances:"
    find "$SCRIPT_PATH/argo-cd/instances/" -mindepth 1 -maxdepth 1 -type d \
      ! -name '_*' -exec basename {} \; 2>/dev/null | sed 's/^/  /' || echo "  (none)"
    exit 1
  fi

  if [[ ! -f "$instance_dir/instance.yaml" ]]; then
    error "Missing instance.yaml: $instance_dir/instance.yaml"
    exit 1
  fi

  if [[ ! -f "$values_file" ]]; then
    error "ohmlab values not found: $values_file"
    exit 1
  fi

  check_kubectl
  check_helm

  log "Bootstrapping ohmlab for instance: $instance"

  log "Updating chart dependencies..."
  helm dependency update "$SCRIPT_PATH/homelab-utils/helm" >/dev/null

  # Phase 1: If ArgoCD CRDs don't exist yet, install the chart with only
  # ArgoCD enabled (CRDs + core components). This solves the chicken-and-egg
  # where AppProject/Application/HTTPRoute resources need CRDs from the same release.
  if ! kubectl get crd applications.argoproj.io &>/dev/null; then
    log "ArgoCD CRDs not present — phase 1: installing ArgoCD components only..."

    # Install Gateway API CRDs first if the chart uses HTTPRoutes.
    if ! kubectl get crd httproutes.gateway.networking.k8s.io &>/dev/null; then
      log "Gateway API CRDs not found — installing..."
      kubectl apply --server-side -f \
        https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml 2>/dev/null
      kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=60s
    fi

    helm upgrade --install ohmlab "$SCRIPT_PATH/homelab-utils/helm" \
      --namespace argocd-system \
      --create-namespace \
      --values "$values_file" \
      --set rootManager.enabled=false \
      --set projects.core.enabled=false \
      --set projects.tenant.enabled=false \
      --set gateway.enabled=false \
      --wait \
      --timeout 10m

    log "Phase 1 complete — ArgoCD CRDs and components installed."
  fi

  # Install Gateway API CRDs if still missing (upgrade path where ArgoCD was
  # already present but Gateway API was not).
  if ! kubectl get crd httproutes.gateway.networking.k8s.io &>/dev/null; then
    log "Gateway API CRDs not found — installing..."
    kubectl apply --server-side -f \
      https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml 2>/dev/null
    kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=60s
  fi

  local extra_args=()
  if [[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]]; then
    log "Bcrypt-hashing admin password from \$ARGOCD_ADMIN_PASSWORD..."
    local bcrypt
    bcrypt=$(bcrypt_hash "$ARGOCD_ADMIN_PASSWORD") || exit 1
    extra_args+=(--set-string "argo-cd.configs.secret.argocdServerAdminPassword=$bcrypt")
  fi

  # Phase 2: Full install/upgrade with all resources (AppProjects, root
  # Application, HTTPRoutes). CRDs are now present from phase 1 or prior run.
  log "Installing/upgrading ohmlab release..."
  helm upgrade --install ohmlab "$SCRIPT_PATH/homelab-utils/helm" \
    --namespace argocd-system \
    --create-namespace \
    --values "$values_file" \
    ${extra_args[@]+"${extra_args[@]}"} \
    --wait \
    --timeout 10m

  log "Waiting for ArgoCD server to be ready..."
  kubectl rollout status deployment -n argocd-system \
    -l app.kubernetes.io/name=argocd-server --timeout=300s || true

  success "ohmlab bootstrap complete for instance: $instance"

  if [[ -z "${ARGOCD_ADMIN_PASSWORD:-}" ]]; then
    print_initial_admin_password
  fi
  log ""
  log "The root 'manager' ApplicationSet will now reconcile every instance"
  log "under ./argo-cd/instances/*/ (one per-instance Application per folder,"
  log "each fanning out into core + tenant AppSets)."
  log ""
  log "Monitor progress:"
  log "  kubectl get applications,applicationsets -n argocd-system"
}

# =============================================================================
# Main
# =============================================================================

# Parse options
while getopts "hdekp:t:ub:y" flag; do
  case "${flag}" in
    d) DECRYPT="true" ;;
    e) ENCRYPT="true" ;;
    k) FETCH_KUBECONFIG="true" ;;
    p) PLAYBOOK="${OPTARG}" ;;
    t) TAGS="${OPTARG}" ;;
    u) UPDATE="true" ;;
    b) BOOTSTRAP_INSTANCE="${OPTARG}" ;;
    y) YES="true" ;;
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
if [[ -n "$BOOTSTRAP_INSTANCE" ]]; then
  bootstrap_instance "$BOOTSTRAP_INSTANCE"
fi

# Show help if no action was taken
if [[ "$DECRYPT" == "false" && "$ENCRYPT" == "false" && "$UPDATE" == "false" && \
      -z "$PLAYBOOK" && "$FETCH_KUBECONFIG" == "false" && -z "$BOOTSTRAP_INSTANCE" ]]; then
  print_help
fi
