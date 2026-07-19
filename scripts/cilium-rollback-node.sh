#!/bin/bash

set -e
set -o pipefail

# Roll ONE node back from Cilium to flannel (rolling migration window ONLY —
# before the final k3s flag flip; after that, flannel no longer exists).
# Runbook: .local/cilium-migration-plan.md (F8).
#
# Usage: scripts/cilium-rollback-node.sh <node>   (e.g. pi8)
# SSH:   uses the <node> alias from ~/.ssh/config; sudo prompts for the
#        password — expected.

NODE="${1:?usage: $0 <node>}"
MIGRATION_LABEL="io.cilium.migration/cilium-default"
K3S_CNI_DIR="/var/lib/rancher/k3s/agent/etc/cni/net.d"
READY_TIMEOUT=420

say() { printf '\n==> %s\n' "$*"; }

say "Cordon + drain ${NODE}"
kubectl cordon "${NODE}"
kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --timeout=300s || true

say "Remove the migration label from ${NODE}"
kubectl label node "${NODE}" "${MIGRATION_LABEL}-" || true

say "Remove the Cilium conflist on ${NODE} (k3s regenerates flannel's on boot)"
ssh -t "${NODE}" "sudo sh -c 'rm -f ${K3S_CNI_DIR}/05-cilium.conflist; for f in ${K3S_CNI_DIR}/*.cilium_bak; do [ -e \"\$f\" ] && mv \"\$f\" \"\${f%.cilium_bak}\"; done; true'"

say "Rebooting ${NODE} (sudo will prompt for the password)"
ssh -t "${NODE}" sudo systemctl reboot || true

say "Waiting for ${NODE} to come back Ready (max ${READY_TIMEOUT}s)"
sleep 20
end=$((SECONDS + READY_TIMEOUT))
until kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  [ $SECONDS -ge $end ] && { echo "ERROR: ${NODE} not Ready after ${READY_TIMEOUT}s"; exit 1; }
  sleep 10
done
echo "OK: ${NODE} Ready"

say "Gate: new pods on ${NODE} are flannel-managed again (10.42.x)"
echo "  check: kubectl get pods -A -o wide --field-selector spec.nodeName=${NODE} | grep 10.42."

read -r -p "Uncordon ${NODE} now? [y/N] " ans
if [ "${ans}" = "y" ] || [ "${ans}" = "Y" ]; then
  kubectl uncordon "${NODE}"
  echo "Done — ${NODE} back on flannel."
else
  echo "Left cordoned. Uncordon manually: kubectl uncordon ${NODE}"
fi
