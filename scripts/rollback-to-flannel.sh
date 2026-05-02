#!/usr/bin/env bash
# ============================================================================
# Rollback: Cilium → Flannel
# ============================================================================
# Use this if Cilium migration failed and you need to restore flannel.
#
# This script:
#   1. Reverts K3s flags (removes --flannel-backend=none etc.)
#   2. Stops K3s on all nodes
#   3. Cleans Cilium state
#   4. Restarts K3s with flannel
#   5. Disables Cilium in ArgoCD
#
# Prerequisites:
#   - SSH access to all nodes
#   - Run from the homelab repo root
# ============================================================================

set -euo pipefail

MASTERS=(pi3 pi0 pi4)
WORKERS=(pi1 pi2 pi5 pi6 pi7 pi8)
ALL_NODES=("${MASTERS[@]}" "${WORKERS[@]}")
ANSIBLE_DIR="$(cd "$(dirname "$0")/../ansible" && pwd)"
K3S_YML="$ANSIBLE_DIR/inventory/group_vars/k3s.yml"
CORE_YAML="$(cd "$(dirname "$0")/.." && pwd)/argo-cd/instances/homelab/core.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*"; }

confirm() {
  echo ""
  warn "This will REVERT to flannel networking."
  warn "All pods will be terminated and recreated."
  echo ""
  read -rp "Type 'rollback' to proceed: " answer
  if [[ "$answer" != "rollback" ]]; then
    echo "Aborted."
    exit 0
  fi
}

# ============================================================================
# Phase 1: Revert K3s inventory vars
# ============================================================================
revert_k3s_config() {
  log "Phase 1: Reverting K3s inventory to flannel mode..."

  # Check if the file has Cilium flags
  if ! grep -q 'flannel-backend=none' "$K3S_YML"; then
    log "k3s.yml already in flannel mode — skipping."
    return 0
  fi

  cat > "$K3S_YML" <<'K3S_EOF'
k3sVersion: "v1.35.3+k3s1"
k3sToken: "{{ vault_k3s_token }}"
k3sCaData: "{{ vault_k3s_ca_data }}"
k3sDatastoreEndpoint: "https://{{ hostvars[groups['gateway'][0]]['ansible_host'] }}:2379"
k3sSystemdDir: "/etc/systemd/system"
k3sDataDir: "/var/lib/rancher/k3s"
k3sFlanneliface: "eth0"
k3sApiServerEndpoint: "{{ hostvars[groups['gateway'][0]]['ansible_host'] }}"
k3sMasterIP: "{{ hostvars[groups['masters'][0]]['ansible_host'] }}"
k3sNodeIP: "{{ ansible_facts['eth0']['ipv4']['address'] }}"
k3sExtraArgs: >-
  --node-name {{ inventory_hostname }}  --node-ip={{ k3sNodeIP }}  --flannel-iface {{ k3sFlanneliface }}
k3sExtraServerArgs: >-
  {{ k3sExtraArgs }}  --tls-san {{ hostvars[groups['gateway'][0]]['ansible_host'] }}  --disable local-storage  --disable traefik  --write-kubeconfig-mode 600  --node-label node-type=master
# --etcd-arg heartbeat-interval=250  --etcd-arg election-timeout=2500
k3sExtraAgentArgs: >-
  {{ k3sExtraArgs }}  --node-label node-type=worker
K3S_EOF

  log "k3s.yml reverted to flannel mode."
}

# ============================================================================
# Phase 2: Disable Cilium in ArgoCD
# ============================================================================
disable_cilium_argocd() {
  log "Phase 2: Disabling Cilium in core.yaml..."

  if grep -q 'app: cilium' "$CORE_YAML"; then
    # Only change the cilium entry — match the 2 lines (app: cilium + enabled)
    sed -i '' '/app: cilium/{n;s/enabled: "true"/enabled: "false"  # Rollback — reverted to flannel/;}' "$CORE_YAML"
  fi

  log "Cilium disabled in core.yaml."
}

# ============================================================================
# Phase 3: Stop K3s
# ============================================================================
stop_k3s() {
  log "Phase 3: Stopping K3s on all nodes..."

  for node in "${WORKERS[@]}"; do
    log "  Stopping $node..."
    ssh -o ConnectTimeout=10 "$node" 'sudo systemctl stop k3s.service' 2>/dev/null || warn "Failed: $node"
  done

  for node in "${MASTERS[@]}"; do
    log "  Stopping $node..."
    ssh -o ConnectTimeout=10 "$node" 'sudo systemctl stop k3s.service' 2>/dev/null || warn "Failed: $node"
  done
}

# ============================================================================
# Phase 4: Clean Cilium state
# ============================================================================
clean_cilium() {
  log "Phase 4: Cleaning Cilium state on all nodes..."

  for node in "${ALL_NODES[@]}"; do
    log "  Cleaning $node..."
    ssh "$node" 'sudo bash -s' <<'CLEAN_EOF'
      ip link delete cilium_host 2>/dev/null || true
      ip link delete cilium_net 2>/dev/null || true
      ip link delete cilium_vxlan 2>/dev/null || true

      rm -rf /var/lib/cni/ 2>/dev/null || true
      rm -f /var/lib/rancher/k3s/agent/etc/cni/net.d/05-cilium.conflist 2>/dev/null || true

      # Clean BPF state
      rm -rf /sys/fs/bpf/tc 2>/dev/null || true
      rm -rf /sys/fs/bpf/cilium 2>/dev/null || true

      # Flush iptables
      IPT="/var/lib/rancher/k3s/data/current/bin/aux/iptables"
      [ -x "$IPT" ] || IPT="iptables"
      $IPT -F 2>/dev/null || true
      $IPT -t nat -F 2>/dev/null || true
      $IPT -t mangle -F 2>/dev/null || true

      echo "  $HOSTNAME: clean"
CLEAN_EOF
  done
}

# ============================================================================
# Phase 5: Redeploy K3s with flannel and restart
# ============================================================================
redeploy_k3s() {
  log "Phase 5: Redeploying K3s with flannel via Ansible..."

  cd "$ANSIBLE_DIR"

  log "  Deploying masters..."
  ansible-playbook install.yml --tags k3s-masters -i inventory/hosts.yml --diff 2>&1 | tail -15

  log "  Deploying workers..."
  ansible-playbook install.yml --tags k3s-workers -i inventory/hosts.yml --diff 2>&1 | tail -15

  log "K3s redeployed with flannel."
}

# ============================================================================
# Phase 6: Verify
# ============================================================================
verify() {
  log "Phase 6: Waiting for cluster..."

  local retries=60
  for i in $(seq 1 $retries); do
    if kubectl get nodes &>/dev/null; then
      break
    fi
    echo -n "."
    sleep 5
  done

  echo ""
  kubectl get nodes
  echo ""
  log "Verify flannel routes:"
  ssh pi0 'ip route | grep flannel' 2>/dev/null || warn "No flannel routes on pi0"
  echo ""
  log "Rollback complete."
  log ""
  log "Next steps:"
  log "  1. Commit & push the reverted k3s.yml and core.yaml"
  log "  2. Delete Cilium ArgoCD app: kubectl delete app homelab-cilium -n argocd-system"
  log "  3. Remove Cilium taints: for n in pi{0..8}; do kubectl taint nodes \$n node.cilium.io/agent-not-ready:NoSchedule- 2>/dev/null; done"
}

# ============================================================================
# Main
# ============================================================================
main() {
  log "=== Cilium → Flannel Rollback ==="
  confirm
  revert_k3s_config
  disable_cilium_argocd
  stop_k3s
  clean_cilium
  redeploy_k3s
  verify
  log "=== Rollback Done ==="
}

main "$@"
