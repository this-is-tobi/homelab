#!/bin/bash

set -e
set -o pipefail

# Migrate ONE node from flannel to Cilium (rolling migration, per-node step).
# Runbook of record: .local/cilium-migration-plan.md (F8) — run this only
# during the migration window (cilium app deployed DORMANT + CiliumNodeConfig
# present), with the watchdog armed (--tags cilium-watchdog) and a second SSH
# session open to the node.
#
# Usage: scripts/cilium-migrate-node.sh <node>   (e.g. pi8)
# SSH:   uses the <node> alias from ~/.ssh/config; sudo prompts for the
#        password (no passwordless sudo on the fleet) — that is expected.
#
# Rollback at any point: scripts/cilium-rollback-node.sh <node>

NODE="${1:?usage: $0 <node>}"
MIGRATION_LABEL="io.cilium.migration/cilium-default"
CILIUM_POD_CIDR="10.45."
READY_TIMEOUT=420

say() { printf '\n==> %s\n' "$*"; }

say "Pre-flight checks for ${NODE}"
kubectl get node "${NODE}" >/dev/null
NODE_IP="$(kubectl get node "${NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
kubectl -n kube-system get ciliumnodeconfig cilium-migration >/dev/null \
  || { echo "ERROR: CiliumNodeConfig 'cilium-migration' missing — is the cilium app deployed with migration.enabled=true?"; exit 1; }
CILIUM_POD="$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=${NODE}" -o name | head -1)"
[ -n "${CILIUM_POD}" ] || { echo "ERROR: no cilium agent pod on ${NODE} — dormant install not running there"; exit 1; }
kubectl -n kube-system wait --for=condition=Ready "${CILIUM_POD}" --timeout=60s >/dev/null
echo "OK: node ${NODE} (${NODE_IP}), dormant cilium agent ready"

say "Cordon + drain ${NODE}"
kubectl cordon "${NODE}"
kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --timeout=300s

say "Label ${NODE} for Cilium CNI ownership"
kubectl label node "${NODE}" "${MIGRATION_LABEL}=true" --overwrite

say "Rebooting ${NODE} (sudo will prompt for the password)"
ssh -t "${NODE}" sudo systemctl reboot || true

say "Waiting for ${NODE} to come back Ready (max ${READY_TIMEOUT}s)"
sleep 20
end=$((SECONDS + READY_TIMEOUT))
until kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  [ $SECONDS -ge $end ] && { echo "ERROR: ${NODE} not Ready after ${READY_TIMEOUT}s — watchdog reboots at ~5min; check console/SSH"; exit 1; }
  sleep 10
done
echo "OK: ${NODE} Ready"

say "Gate: cilium agent healthy on ${NODE}"
CILIUM_POD="$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=${NODE}" -o name | head -1)"
kubectl -n kube-system wait --for=condition=Ready "${CILIUM_POD}" --timeout=180s

say "Gate: ${NODE} allocated a Cilium pod CIDR (${CILIUM_POD_CIDR}x)"
kubectl get ciliumnode "${NODE}" -o jsonpath='{.spec.ipam.podCIDRs}' | grep -q "${CILIUM_POD_CIDR}" \
  || { echo "ERROR: ciliumnode ${NODE} has no ${CILIUM_POD_CIDR}x CIDR"; kubectl get ciliumnode "${NODE}" -o jsonpath='{.spec.ipam.podCIDRs}'; exit 1; }
echo "OK: $(kubectl get ciliumnode "${NODE}" -o jsonpath='{.spec.ipam.podCIDRs}')"

say "Gate: hostPort 443 still answers on ${NODE_IP} (svclb/portmap — plan F4)"
curl -sk -o /dev/null --connect-timeout 5 "https://${NODE_IP}:443/" \
  && echo "OK: TLS answered on ${NODE_IP}:443" \
  || { echo "ERROR: nothing listening on ${NODE_IP}:443 — portmap chaining broken, DO NOT continue"; exit 1; }

say "MANUAL gates before uncordon (second terminal):"
cat <<EOF
  - SSH to ${NODE} works repeatedly through the full 5-min watchdog window
  - sudo tc filter show dev eth0 ingress   -> empty
  - sudo tc filter show dev eth0 egress    -> empty
  - a new pod on ${NODE} gets a ${CILIUM_POD_CIDR}x IP and resolves/reaches
    pods on a flannel node (and the reverse direction)
EOF
read -r -p "Uncordon ${NODE} now? [y/N] " ans
if [ "${ans}" = "y" ] || [ "${ans}" = "Y" ]; then
  kubectl uncordon "${NODE}"
  echo "Done. Soak before the next node (canary: >=30 min)."
else
  echo "Left cordoned. Uncordon manually: kubectl uncordon ${NODE}"
fi
