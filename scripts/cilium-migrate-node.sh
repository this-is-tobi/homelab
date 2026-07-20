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

say "Restart the cilium agent on ${NODE} (CiliumNodeConfig is start-time only)"
# A running agent never re-reads per-node config (pi7 lesson, 2026-07-20):
# without this bounce the conf is only written mid-boot after the reboot —
# too late, flannel wins the early sandboxes. Safe here: node is cordoned.
CILIUM_POD="$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=${NODE}" -o name | head -1)"
kubectl -n kube-system delete "${CILIUM_POD}" --wait=true >/dev/null
CILIUM_POD=""
until [ -n "${CILIUM_POD}" ] && [ "$(kubectl -n kube-system get "${CILIUM_POD}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ]; do
  CILIUM_POD="$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=${NODE}" -o name 2>/dev/null | head -1)"
  sleep 5
done
echo "OK: agent restarted (${CILIUM_POD})"

say "Waiting for the agent to write the Cilium CNI conf (pre-reboot gate)"
# Rebooting before the conf lands on disk lets k3s's flannel win the early
# boot and DS pods come up with flannel IPs (canary lesson, 2026-07-20).
end=$((SECONDS + 120))
until kubectl -n kube-system exec "${CILIUM_POD#pod/}" -c cilium-agent -- test -f /host/etc/cni/net.d/05-cilium.conflist 2>/dev/null; do
  [ $SECONDS -ge $end ] && { echo "ERROR: conf not written 120s after agent restart — check CiliumNodeConfig + agent logs"; exit 1; }
  sleep 5
done
echo "OK: 05-cilium.conflist present on ${NODE}"

BOOT_ID="$(ssh "${NODE}" cat /proc/sys/kernel/random/boot_id)"
say "Rebooting ${NODE} (sudo will prompt for the password)"
ssh -t "${NODE}" sudo systemctl reboot || true

say "Waiting for ${NODE} to actually reboot (boot-id change), then Ready (max ${READY_TIMEOUT}s)"
# The API keeps reporting stale Ready=True for ~1min after a node goes down —
# waiting on Ready alone races the reboot (canary lesson, 2026-07-20).
end=$((SECONDS + READY_TIMEOUT))
until [ "$(ssh -o ConnectTimeout=4 -o BatchMode=yes "${NODE}" cat /proc/sys/kernel/random/boot_id 2>/dev/null)" != "${BOOT_ID}" ] \
      && ssh -o ConnectTimeout=4 -o BatchMode=yes "${NODE}" true 2>/dev/null; do
  [ $SECONDS -ge $end ] && { echo "ERROR: ${NODE} did not come back after ${READY_TIMEOUT}s — watchdog reboots at ~5min; check console"; exit 1; }
  sleep 10
done
echo "OK: ${NODE} rebooted (new boot-id)"
until kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  [ $SECONDS -ge $end ] && { echo "ERROR: ${NODE} not Ready after ${READY_TIMEOUT}s"; exit 1; }
  sleep 10
done
echo "OK: ${NODE} Ready"

say "Gate: cilium agent healthy on ${NODE}"
CILIUM_POD="$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=${NODE}" -o name | head -1)"
kubectl -n kube-system wait --for=condition=Ready "${CILIUM_POD}" --timeout=180s

say "Gate: every pod on ${NODE} runs on a Cilium IP (${CILIUM_POD_CIDR}x)"
# The ciliumnode CIDR exists from the dormant install already — the real
# cutover proof is the PODS' IPs. Flannel-IP stragglers (sandboxes created
# in the boot window before the agent was ready) are deleted so their DS
# recreates them under Cilium.
end=$((SECONDS + 180))
while :; do
  STRAGGLERS="$(kubectl get pods -A --field-selector "spec.nodeName=${NODE}" -o json \
    | jq -r '.items[] | select(.spec.hostNetwork != true) | select(.status.podIP // "" | startswith("10.42.")) | "\(.metadata.namespace)/\(.metadata.name)"')"
  [ -z "${STRAGGLERS}" ] && break
  [ $SECONDS -ge $end ] && { echo "ERROR: flannel-IP pods persist on ${NODE}:"; echo "${STRAGGLERS}"; exit 1; }
  echo "deleting flannel-IP stragglers:"; echo "${STRAGGLERS}"
  echo "${STRAGGLERS}" | while IFS=/ read -r ns name; do kubectl delete pod -n "$ns" "$name" --wait=false; done
  sleep 20
done
echo "OK: all podNet pods on ${NODE} are on ${CILIUM_POD_CIDR}x"

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
