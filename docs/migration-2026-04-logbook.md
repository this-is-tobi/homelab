# Migration April 2026 — Live Logbook

Chronological record of every issue encountered during the live migration of the
`homelab` instance from the legacy single-level Argo CD layout to the new
two-level AppSet pattern. Each entry contains the symptom, the root cause and
the exact remediation applied so the same recovery can be replayed (or
prevented) on other instances.

> Sister documents: [migration-2026-04.md](migration-2026-04.md) (intended
> migration plan), [03-installation.md](03-installation.md) (steady-state install).

---

## Table of contents

1. [Argo CD bootstrap](#1-argo-cd-bootstrap)
2. [Manager / AppSet templating](#2-manager--appset-templating)
3. [Longhorn control-plane recovery](#3-longhorn-control-plane-recovery)
4. [Vault cluster recovery](#4-vault-cluster-recovery)
5. [Misc / helper scripts](#5-misc--helper-scripts)
6. [Lessons learned](#6-lessons-learned)

---

## 1. Argo CD bootstrap

### 1.1 Old `argo-cd-system` Helm release CRDs blocked the new install

- **Symptom**: `helm install homelab-core …` fails with
  `Unable to continue with install: CustomResourceDefinition "applications.argoproj.io" exists and cannot be imported`.
- **Cause**: CRDs from the previous Argo CD release (`argo-cd-system`) carried
  `meta.helm.sh/release-name=argo-cd-system` annotations; Helm refused to
  re-own them under the new release name `homelab-core`.
- **Fix**: re-annotate the CRDs in place before retrying the install.

  ```sh
  for crd in $(kubectl get crd -l app.kubernetes.io/part-of=argocd -o name); do
    kubectl annotate "$crd" \
      meta.helm.sh/release-name=homelab-core \
      meta.helm.sh/release-namespace=argocd-system --overwrite
    kubectl label "$crd" app.kubernetes.io/managed-by=Helm --overwrite
  done
  ```

### 1.2 Bootstrap Ingress had empty TLS hosts (helm chart default)

- **Symptom**: `homelab-core` install succeeds but the rendered Argo CD Ingress
  has an empty `host` and `tls.hosts: [""]`, breaking cert-manager and the
  applicationSet webhook.
- **Cause**: Default values in the upstream chart leave both `server.ingress`
  and `applicationSet.webhook.ingress` mostly empty, but expand `extraTls`
  unconditionally with an empty entry.
- **Fix**: explicitly override both ingress blocks (and force `extraTls: []`)
  in [argo-cd/instances/homelab/values/core/homelab-core.yaml](argo-cd/instances/homelab/values/core/homelab-core.yaml):

  ```yaml
  argo-cd:
    server:
      ingress:
        enabled: true
        hostname: core.gitops.ohmlab.fr
        annotations: { ... }
        tls: true
        extraTls: []          # required: chart default expands [{ hosts: [""] }]
    applicationSet:
      webhook:
        ingress:
          enabled: true
          hostname: appset.core.gitops.ohmlab.fr
          tls: true
          extraTls: []
  ```

### 1.3 `run.sh` failed under `set -u` with empty extra-args array

- **Symptom**: `./run.sh -b homelab` aborts with
  `extra_args[@]: unbound variable` when no `--set` overrides are provided.
- **Fix**: guard the array expansion in [run.sh](run.sh) (line 354):

  ```sh
  helm upgrade --install ... ${extra_args[@]+"${extra_args[@]}"}
  ```

### 1.4 Bootstrap certificates: HTTP-01 chicken-and-egg with ingress-nginx

- **Symptom**: After `homelab-core` install, `homelab-cert-manager` Argo CD app
  reports `Degraded`. The only failing object is the `argocd-server-tls`
  Certificate, stuck on
  `Issuing certificate as Secret does not exist` with the order's HTTP-01
  challenge never reaching `valid`.
- **Cause**: The Argo CD server Ingress is annotated with the HTTP-01
  ClusterIssuer (`letsencrypt-http-prod`), but during bootstrap **ingress-nginx
  is not yet running** (it is an `argocd-system` tenant app synced *after*
  Argo CD itself). cert-manager creates the solver Pod/Service/Ingress, but
  there is no LB to route ACME traffic, so the challenge times out.
- **Fix**: switch every bootstrap-critical Ingress to the DNS-01 ClusterIssuer
  (`letsencrypt-dns-prod`), which only needs Scaleway DNS API access — no
  ingress controller required. Applied to
  [argo-cd/instances/homelab/values/core/homelab-core.yaml](argo-cd/instances/homelab/values/core/homelab-core.yaml)
  and the matching `_example` core values:

  ```yaml
  argo-cd:
    server:
      ingress:
        annotations:
          # DNS-01 issuer: works during bootstrap before ingress-nginx is
          # available, and supports wildcards / private hosts.
          cert-manager.io/cluster-issuer: letsencrypt-dns-prod
    applicationSet:
      webhook:
        ingress:
          annotations:
            cert-manager.io/cluster-issuer: letsencrypt-dns-prod
  ```

  To force re-issuance live (without waiting for the renewal window):

  ```sh
  kubectl -n argocd-system annotate ingress homelab-core-argocd-server \
    cert-manager.io/cluster-issuer=letsencrypt-dns-prod --overwrite
  kubectl -n argocd-system delete certificate argocd-server-tls
  kubectl -n argocd-system delete secret      argocd-server-tls
  ```

- **Rule of thumb**: any Certificate that must be valid *before* ingress-nginx
  is up — Argo CD server, Argo CD AppSet webhook, Vault UI, Longhorn UI — must
  use DNS-01. Tenant apps that are synced after ingress-nginx may keep
  HTTP-01.

### 1.5 AppSet webhook Ingress not rendered

- **Observation**: even with `applicationSet.webhook.ingress.enabled: true`,
  no `homelab-core-argocd-applicationset` Ingress object exists in
  `argocd-system`. Only `homelab-core-argocd-server` is present.
- **Impact**: harmless during bootstrap (the webhook URL is optional — Argo CD
  falls back to its 3-minute reconcile loop), but means GitHub/Gitea push
  events do not trigger immediate AppSet generation.
- **Status**: deferred. To investigate later: chart values key may have moved
  in a recent argo-cd Helm chart version, or the bitnami-style nesting
  (`applicationSet.webhook.ingress`) needs an inner `enabled: true` on a
  different sub-key.

---

## 2. Manager / AppSet templating

### 2.1 `goTemplateOptions: missingkey=error` broke `default` calls

- **Symptom**: `instance-homelab` Application stays `Unknown/Unknown`; both
  child AppSets render error
  `template: …: map has no entry for key "hook"` (and later `destination.server`).
- **Cause**: `goTemplateOptions: ["missingkey=error"]` makes
  `{{ default "Sync" .hook }}` fail when `.hook` is absent from the catalog
  entry — `default` only runs after the lookup succeeds.
- **Fix**: drop both the option and the offending annotation in
  [argo-cd/apps/instance-manager/templates/appset-core.yaml](argo-cd/apps/instance-manager/templates/appset-core.yaml)
  and [appset-tenant.yaml](argo-cd/apps/instance-manager/templates/appset-tenant.yaml).
  Templates now use plain `{{ .hook | default "Sync" }}` style or omit the
  field entirely.

### 2.2 Repo credentials secret labelling

- **Symptom**: Manager AppSet rendered Apps but they all reported
  `repository not found`.
- **Cause**: The `repo-…` Secret created by the `argocd login` flow lacked
  `argocd.argoproj.io/secret-type=repository` after migrating to the new
  namespace `argocd-system`.
- **Fix**: re-label the secret and ensure the `url` data key matches the
  Application's `repoURL` exactly (no trailing slash, scheme included).

---

## 3. Longhorn control-plane recovery

> Longhorn was the largest source of incidents; its data plane (engines,
> replicas, instance-manager pods) survived intact, but its control plane
> (`longhorn-manager` DaemonSet + admission webhooks) was missing/broken from
> a previous failed upgrade. Several layers of stale state had to be cleaned
> before the new chart could reconcile.

### 3.1 Webhook configurations referencing a deleted Service

- **Symptom**: every CR mutation (`Volume`, `Engine`, `Replica`, `Node`) failed
  with `Internal error occurred: failed calling webhook … service longhorn-admission-webhook not found`.
- **Cause**: leftover `MutatingWebhookConfiguration longhorn-webhook-mutator`
  and `ValidatingWebhookConfiguration longhorn-webhook-validator` from a prior
  install; the Service was already deleted.
- **Fix**:

  ```sh
  kubectl delete mutatingwebhookconfiguration   longhorn-webhook-mutator
  kubectl delete validatingwebhookconfiguration longhorn-webhook-validator
  ```

  The next sync of the `longhorn` chart recreates them pointing to the live
  service.

### 3.2 `longhorn-manager` DaemonSet was completely missing

- **Symptom**: `kubectl -n longhorn-system get ds` shows only
  `engine-image-ei-*` and `longhorn-csi-plugin`. No reconciliation happens —
  volumes get stuck in any non-current state, instance-manager CRs are not
  pruned, attachments hang.
- **Cause**: a previous upgrade had been partially destroyed; only the data
  plane survived.
- **Fix**: trigger a fresh sync of the `homelab-longhorn` Application. The
  Helm chart re-creates the DaemonSet, `longhorn-driver-deployer`,
  `longhorn-ui` Deployment and webhook configurations.

### 3.3 Helm pre-upgrade hook needs the SA the chart itself creates

- **Symptom**: after triggering the sync, the pre-upgrade hook Job
  `longhorn-pre-upgrade` stays at `0/1 Active`; events show
  `Error creating: pods "longhorn-pre-upgrade-" is forbidden: error looking up
  service account longhorn-system/longhorn-service-account`.
- **Cause**: the chart attaches the hook to a SA that is itself created by a
  non-hook manifest of the same chart, so on the very first install/sync the
  SA does not yet exist when the hook runs.
- **Fix**: bootstrap the SA + RBAC manually so the hook can complete; the
  chart will re-own them on the next pass.

  ```sh
  kubectl -n longhorn-system create sa longhorn-service-account
  kubectl create clusterrolebinding longhorn-service-account-tmp \
    --clusterrole=cluster-admin \
    --serviceaccount=longhorn-system:longhorn-service-account
  # then re-trigger the Argo CD sync
  ```

  Once Longhorn is `Synced/Healthy`, the temporary `clusterrolebinding` can be
  deleted; the chart-managed RBAC is in effect.

### 3.4 Stale `node.longhorn.io` and `instancemanager.longhorn.io` for removed nodes

- **Symptom**: `longhorn-manager` logs spam every 30 s with
  `Instance manager pod instance-manager-… is not found, recreating the pod`
  for nodes that no longer host longhorn (here `pi0`, `pi3`, `pi4` —
  control-plane nodes that were never part of the storage pool but were
  registered before the chart was changed to skip masters).
- **Attempted fix** (failed): direct delete is rejected because `Node` CRs
  with `Manager pod is missing` cannot be deleted; clearing the finalizer
  alone is also rejected.
- **Acceptable workaround**: the loop is noisy but not blocking; it disappears
  once the chart re-applies its `nodeSelector`/taints. To stop it cold the
  full procedure is:

  1. Cordon the node in Longhorn UI (`AllowScheduling=false`).
  2. Wait for replicas/engines to drain (none here, since they were never
     scheduled).
  3. Delete the `node.longhorn.io` (succeeds once `Manager pod is missing`
     condition turns to `KubernetesNodeMissing`).

### 3.5 `assignment to entry in nil map` panic on volume attach (v1.11.1)

- **Symptom**: `csi-attacher` reports
  `rpc error: code = Internal desc = Post "http://longhorn-backend:9500/v1/volumes/<pv>?action=attach": EOF`.
  Manager logs show:

  ```
  http: panic serving …: assignment to entry in nil map
  github.com/longhorn/longhorn-manager/manager.(*VolumeManager).Attach
        /app/manager/volume.go:280
  ```

- **Cause**: when the matching `volumeattachment.longhorn.io` CR has
  `spec.attachmentTickets: nil` (rather than `{}`), the manager tries to write
  into the nil map and crashes the HTTP handler.
- **Fix**: pre-initialise the map on every offending VA before re-triggering
  the attach.

  ```sh
  kubectl -n longhorn-system patch volumeattachment.longhorn.io <pv-name> \
    --type=merge -p '{"spec":{"attachmentTickets":{}}}'
  # then delete the consumer pod so kubelet retries the CSI attach
  ```

  The CSI attacher then populates the ticket and the volume attaches normally.

### 3.6 Engines stuck on a node where the consumer pod is no longer scheduled

- **Symptom**: pod is scheduled on `piX` but the volume's `status.currentNodeID`
  remains `piY`; attach fails until the engine moves.
- **Fix options** (in increasing invasiveness):

  1. Restart the `longhorn-manager` DaemonSet so reconcile loops re-evaluate.
  2. Delete the consumer pod with `--grace-period=0 --force`; the StatefulSet
     reschedules and CSI re-issues the attach.
  3. Cordon the unwanted nodes so the pod lands on the node that already
     holds a healthy replica/engine.

---

## 4. Vault cluster recovery

> The Vault data was intact and the unseal keys were preserved, but the
> Banzai-Cloud-managed `vault` StatefulSet had been down for the full
> Longhorn outage. Bringing it back required handling the chicken-and-egg of
> raft quorum vs `OrderedReady`, plus a corrupted bbolt file on `vault-2`.

### 4.1 `OrderedReady` deadlock

- **Symptom**: `vault-0` enters `CrashLoopBackOff` because it cannot reach
  raft quorum on its own; `vault-1` is never created because the StatefulSet
  uses `podManagementPolicy=OrderedReady` and waits for `vault-0` to be Ready.
- **Cause**: a 1-of-3 raft cluster cannot establish quorum and the bank-vaults
  health probe fails, so the pod restarts forever.
- **Fix**: kubernetes' `OrderedReady` accepts pods that have ever been
  `Ready`; once `vault-0` flaps to `Ready` (even briefly), `vault-1` is
  created. Force progress by:

  1. Letting `vault-0` reach `Init:0/1 → Running 2/3` once.
  2. Force-deleting `vault-0` if it does not flap (`kubectl delete pod vault-0
     --grace-period=0 --force`); the readiness probe on the freshly-attached
     volume usually succeeds for long enough to unblock `vault-1`.
  3. Repeat for `vault-2`.

  *Avoid* switching the SST to `Parallel` — Kubernetes forbids that field
  update on an existing StatefulSet (`spec: Forbidden: updates to
  statefulset spec for fields other than 'replicas', …`).

### 4.2 vault-2 bbolt raft DB corrupted

- **Symptom**:

  ```
  panic: freepages: failed to get all reachable pages
  (page 6795: multiple references (stack: [1000 4525 1690 6795]))
  go.etcd.io/bbolt.(*DB).freepages.func2()
  ```

- **Cause**: ungraceful shutdown during the previous outage corrupted
  `/vault/file/raft/raft.db` on the `vault-2` PVC.
- **Fix**: remove the peer from raft, drop its PVC, let the StatefulSet
  recreate it as a fresh follower.

  ```sh
  TOKEN=$(kubectl -n vault-operator-system get secret vault-unseal-keys \
    -o jsonpath='{.data.vault-root}' | base64 -d)

  kubectl -n vault-operator-system exec vault-0 -c vault -- sh -c "
    VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN=$TOKEN \
    vault operator raft list-peers"

  # Identify the corrupt peer's node-id and remove it
  kubectl -n vault-operator-system exec vault-0 -c vault -- sh -c "
    VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN=$TOKEN \
    vault operator raft remove-peer <node-id>"

  # Recreate the PVC
  kubectl -n vault-operator-system scale sts vault --replicas=2
  sleep 10
  kubectl -n vault-operator-system delete pvc vault-raft-vault-2 --wait=false
  kubectl -n vault-operator-system scale sts vault --replicas=3
  ```

  The new `vault-2` joins as a follower, replicates from `vault-1` (current
  leader), and the cluster returns to 3-voter health.

### 4.3 Verifying recovery

```sh
TOKEN=$(kubectl -n vault-operator-system get secret vault-unseal-keys \
  -o jsonpath='{.data.vault-root}' | base64 -d)

kubectl -n vault-operator-system exec vault-0 -c vault -- sh -c "
  VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN=$TOKEN \
  vault operator raft list-peers && \
  vault status"
```

Expected: 3 peers all `Voter true`, `Sealed=false`, `HA Enabled=true`,
`HA Cluster=https://vault-N…:8201`.

---

## 5. Misc / helper scripts

### 5.1 `/tmp/sync_app.sh`

Re-usable wrapper that triggers an Argo CD sync with safe sync options
(`ServerSideApply=true,ApplyOutOfSyncOnly=true,RespectIgnoreDifferences=true`),
polls every 15 s up to 8 times, and prints the resulting app + namespace
state. Used throughout the migration.

### 5.2 `vault-unseal-keys` Secret

Survived the entire incident and is the single source of truth for both the
root token and the unseal shares. Banzai-Cloud's `vault-operator` re-uses it
to auto-unseal pods on restart, so the cluster came back unsealed without
manual intervention once the StatefulSet was up.

### 5.3 Cleanup of `myvitalfamily` / `q-it`

The decommissioned tenant produced two cleanup quirks:

- The `Application` did not have a finalizer (Argo CD CLI policy was
  `non-cascade`), so it deleted instantly without removing children.
- The `q-it` namespace had a `cnpg.io` Cluster CR with finalizers; deleting
  the CR before deleting the namespace lets the operator clean its PVCs.

Order to follow when nuking an instance:

```sh
kubectl -n argo-cd delete application/<name>
kubectl -n <ns> delete cluster.postgresql.cnpg.io --all --ignore-not-found
kubectl -n <ns> delete deploy,sts,svc,ingress,cm,secret,pvc --all --ignore-not-found
kubectl delete ns <ns> --wait=false
```

---

## 6. Lessons learned

- **Always pin Argo CD CRDs to the new release name before touching the chart
  bundle**; Helm's release-ownership check is more important than the actual
  CRD content.
- **Helm pre-upgrade hooks that consume a chart-managed SA are an
  anti-pattern**: bootstrap the SA out-of-band on first install, then let the
  chart re-own it.
- **`goTemplateOptions: missingkey=error` is incompatible with the `default`
  helper for absent keys**; either use `hasKey` guards or remove the option.
- **In Longhorn v1.11.1, `volumeattachment.longhorn.io.spec.attachmentTickets`
  must be `{}` (not nil)** — otherwise the manager's HTTP handler panics.
  Worth filing upstream; defensive `make(map[…])` in `VolumeManager.Attach`
  would prevent it.
- **Bank-vaults `OrderedReady` recovery is fragile**: keep recent raft
  snapshots (the `backup-vault-snapshot` CronJob saved us this time) and be
  ready to manually replay the recreate-PVC dance if a peer's `bbolt` DB
  corrupts.
- **Stale Longhorn node CRs** are noisy but not blocking — clean them via the
  UI rather than CLI to avoid the "node not ready, cannot delete" loop.
- **Use DNS-01 for any cert needed at bootstrap** (Argo CD, AppSet webhook,
  Vault, Longhorn). HTTP-01 only works once ingress-nginx is reachable from
  the public internet — i.e. *after* the tenant tier syncs. Tenant apps
  scheduled after ingress-nginx may safely keep HTTP-01.

---
