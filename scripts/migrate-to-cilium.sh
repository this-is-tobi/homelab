#!/usr/bin/env bash
# ============================================================================
# Flannel → Cilium Full Migration Script
# ============================================================================
# Prerequisites:
#   1. Git changes committed & pushed (k3s.yml, values.yaml, core.yaml)
#   2. SSH access to all nodes (pi0-pi8)
#   3. Run from the homelab repo root
#
# This script:
#   1. Stops K3s on all nodes (workers first, then masters)
#   2. Cleans flannel/Cilium residue on each node
#   3. Deploys new K3s systemd units (via Ansible)
#   4. Starts K3s masters (one at a time, waiting for Ready)
#   5. Starts K3s workers (one at a time)
#   6. Waits for Cilium to be deployed by ArgoCD
#   7. Validates cluster health
#
# Rollback: ./scripts/rollback-to-flannel.sh
# ============================================================================

set -euo pipefail

MASTERS=(pi3 pi0 pi4)  # pi3 first = cluster-init node
WORKERS=(pi1 pi2 pi5 pi6 pi7 pi8)
ALL_NODES=("${MASTERS[@]}" "${WORKERS[@]}")
ANSIBLE_DIR="$(cd "$(dirname "$0")/../ansible" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*"; }

check_ssh() {
  log "Checking SSH connectivity to all nodes..."
  local failed=0
  for node in "${ALL_NODES[@]}"; do
    if ! ssh -o ConnectTimeout=5 "$node" 'echo ok' &>/dev/null; then
      err "Cannot reach $node via SSH"
      failed=1
    fi
  done
  if [[ $failed -eq 1 ]]; then
    err "SSH check failed. Fix connectivity before proceeding."
    exit 1
  fi
  log "All nodes reachable via SSH."
}

confirm() {
  echo ""
  warn "This will cause FULL CLUSTER DOWNTIME."
  warn "All pods will be terminated and recreated."
  echo ""
  echo "Changes applied:"
  echo "  - K3s flags: --flannel-backend=none --disable-network-policy --disable-kube-proxy"
  echo "  - CNI: flannel → Cilium (native routing, kube-proxy replacement)"
  echo "  - Pod CIDR: 10.42.0.0/16 (unchanged)"
  echo ""
  read -rp "Type 'migrate' to proceed: " answer
  if [[ "$answer" != "migrate" ]]; then
    echo "Aborted."
    exit 0
  fi
}

# ============================================================================
# Phase 1: Stop K3s on all nodes
# ============================================================================
stop_k3s() {
  log "Phase 1: Stopping K3s on all nodes..."

  # Workers first (less disruptive to control plane)
  for node in "${WORKERS[@]}"; do
    log "  Stopping K3s on $node..."
    ssh "$node" 'sudo systemctl stop k3s.service' || warn "Failed to stop K3s on $node"
  done

  # Then masters
  for node in "${MASTERS[@]}"; do
    log "  Stopping K3s on $node..."
    ssh "$node" 'sudo systemctl stop k3s.service' || warn "Failed to stop K3s on $node"
  done

  log "K3s stopped on all nodes."
}

# ============================================================================
# Phase 2: Clean networking state
# ============================================================================
clean_networking() {
  log "Phase 2: Cleaning flannel/Cilium residue on all nodes..."

  for node in "${ALL_NODES[@]}"; do
    log "  Cleaning $node..."
    ssh "$node" 'sudo bash -s' <<'CLEAN_EOF'
      # Remove network interfaces
      ip link delete flannel.1 2>/dev/null || true
      ip link delete cni0 2>/dev/null || true
      ip link delete cilium_host 2>/dev/null || true
      ip link delete cilium_net 2>/dev/null || true
      ip link delete cilium_vxlan 2>/dev/null || true

      # Remove CNI state
      rm -rf /run/flannel 2>/dev/null || true
      rm -rf /var/lib/cni/ 2>/dev/null || true
      rm -f /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist 2>/dev/null || true
      rm -f /var/lib/rancher/k3s/agent/etc/cni/net.d/05-cilium.conflist 2>/dev/null || true

      # Flush iptables
      IPT="/var/lib/rancher/k3s/data/current/bin/aux/iptables"
      [ -x "$IPT" ] || IPT="iptables"
      $IPT -F 2>/dev/null || true
      $IPT -t nat -F 2>/dev/null || true
      $IPT -t mangle -F 2>/dev/null || true
      $IPT -X 2>/dev/null || true
      $IPT -t nat -X 2>/dev/null || true
      $IPT -t mangle -X 2>/dev/null || true

      # Clean BPF state
      rm -rf /sys/fs/bpf/tc 2>/dev/null || true
      rm -rf /sys/fs/bpf/cilium 2>/dev/null || true

      echo "  $HOSTNAME: clean"
CLEAN_EOF
  done

  log "Networking state cleaned on all nodes."
}

# ============================================================================
# Phase 3: Deploy new K3s systemd units via Ansible
# ============================================================================
deploy_units() {
  log "Phase 3: Deploying new K3s systemd units via Ansible..."
  log "  This updates the systemd unit files with the new flags."
  log "  K3s will NOT be started yet (Ansible restarts it, but we'll manage startup order)."

  cd "$ANSIBLE_DIR"

  # Deploy masters (updates systemd unit + restarts)
  log "  Deploying masters..."
  ansible-playbook install.yml --tags k3s-masters -i inventory/hosts.yml --diff 2>&1 | tail -20

  # Deploy workers (updates systemd unit + restarts)
  log "  Deploying workers..."
  ansible-playbook install.yml --tags k3s-workers -i inventory/hosts.yml --diff 2>&1 | tail -20

  log "K3s systemd units deployed."
}

# ============================================================================
# Phase 4: Wait for cluster and push Cilium config
# ============================================================================
wait_for_api() {
  log "Phase 4: Waiting for Kubernetes API server..."

  local retries=60
  for i in $(seq 1 $retries); do
    if kubectl get nodes &>/dev/null; then
      log "API server is responding."
      return 0
    fi
    echo -n "."
    sleep 5
  done

  err "API server did not come up after $((retries * 5))s"
  return 1
}

wait_for_nodes() {
  log "Waiting for all 9 nodes to be Ready..."

  local retries=60
  for i in $(seq 1 $retries); do
    local total not_ready
    total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c 'NotReady' || echo "0")
    if [[ "$total" -ge 9 ]] && [[ "$not_ready" -eq 0 ]]; then
      log "All $total nodes Ready."
      kubectl get nodes
      return 0
    fi
    echo -n ".(${total}/${not_ready}nr)"
    sleep 10
  done

  warn "Some nodes not Ready after $((retries * 10))s — Cilium may still be deploying."
  kubectl get nodes
}

# ============================================================================
# Phase 5: Validate
# ============================================================================
validate() {
  log "Phase 5: Validating cluster health..."

  echo ""
  log "=== Nodes ==="
  kubectl get nodes -o wide

  echo ""
  log "=== Cilium pods ==="
  kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium --no-headers 2>/dev/null || echo "No Cilium pods yet"

  echo ""
  log "=== CoreDNS ==="
  kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null || echo "No CoreDNS pods"

  echo ""
  log "=== DNS test ==="
  kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -i --timeout=30s -- \
    nslookup kubernetes.default.svc.cluster.local 2>/dev/null || warn "DNS test failed (may need more time)"

  echo ""
  log "=== ArgoCD apps ==="
  kubectl get application -n argocd-system --no-headers 2>/dev/null | head -20 || echo "ArgoCD not ready yet"

  echo ""
  log "Migration complete. Monitor with:"
  echo "  kubectl get pods -n kube-system -w"
  echo "  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded"
}

# ============================================================================
# Main
# ============================================================================
main() {
  log "=== Flannel → Cilium Migration ==="
  check_ssh
  confirm
  stop_k3s
  clean_networking
  deploy_units
  wait_for_api
  wait_for_nodes
  validate
  log "=== Done ==="
}

main "$@"
