# APISIX → Traefik migration runbook

> Traefik v3 becomes the standing ingress + Gateway API implementation
> (chosen for its small footprint, stateless Kubernetes-API-only config
> and Gateway API conformance — full candidate analysis kept in local
> notes, out of the published docs);
> APISIX (and its etcd) is decommissioned at the end. Written 2026-07;
> tick the checkboxes as phases complete.

## How traffic flows (and why the cutover is per-hostname)

```
internet → gateway HAProxy (TCP passthrough :80/:443)
         → node host ports (klipper-lb svclb)
         → ingress controller pods → Services
```

- klipper-lb binds each LoadBalancer Service's ports as **host ports on every
  node** — only one service can own 80/443. During coexistence Traefik
  exposes **8080 (web) / 8443 (websecure)**.
- HAProxy runs in TCP mode and reads the **SNI** of the TLS ClientHello:
  hostnames listed in `haproxy.traefikHosts` / `traefikHostSuffixes`
  (ansible `inventory/group_vars/gateway.yml`) are forwarded to
  `node:8443`, everything else keeps going to APISIX on `node:443`.
  Cutover granularity = one hostname; rollback = remove it from the list
  and re-run the playbook. No DNS changes at any point.
- Port 80 only serves the HTTPS redirect **plus ACME HTTP-01 solvers** and
  stays on APISIX until the final phase (`haproxy.ingressDefault` flips it).
- Both controllers implement Gateway API. The Traefik gateway
  (`homelab-gateway-traefik`, kube-system) mirrors the APISIX gateway's
  **listener names**, so a route attaches to both gateways with the same
  `sectionName` via `gateway.extraParentRefs` in the app's instance values.
  Both controllers then serve the hostname and HAProxy decides which one
  receives real traffic — the git change and the HAProxy change don't need
  to be simultaneous.

Gotchas encoded in the design:

- **Gateway listener ports are the traefik entryPoint container ports
  (8000/8443)**, not the Service ports — Traefik matches listeners to
  entryPoints by port. Don't "fix" them to 80/443.
- The wildcard TLS secret `gateway-wildcard-tls` (kube-system) is shared by
  both gateways; the cert-manager `Certificate` is **owned by the apisix
  app** until decommission (`gateway.manageCertificate: false` in the
  traefik values prevents an ArgoCD ownership fight).
- TLSRoute (teleport passthrough) needs the Gateway API **experimental**
  CRDs (cluster runs v1.3.0; run.sh installs `experimental-install.yaml`)
  and `providers.kubernetesGateway.experimentalChannel: true` (set).

## Current hostname inventory

| Hostname | App (instance values) | Served via today |
|---|---|---|
| ohmlab.fr | homepage | Ingress + HTTPRoute |
| git.ohmlab.fr | gitea (tenant) | Ingress + HTTPRoute |
| mattermost.ohmlab.fr | mattermost (tenant) | Ingress + HTTPRoute |
| monitoring.ohmlab.fr | prometheus-stack | Ingress + HTTPRoute |
| sso.core.ohmlab.fr | keycloak | Ingress + HTTPRoute |
| vault.core.ohmlab.fr | vault-operator | Ingress + HTTPRoute |
| longhorn.core.ohmlab.fr | longhorn | Ingress (define `gateway.routes`) |
| gitops.core.ohmlab.fr (+appset) | argo-cd / ohmlab | Ingress (define `gateway.routes`) |
| s3.ohmlab.fr / console.s3.ohmlab.fr | rustfs (tenant) | Ingress (define `gateway.routes`) |
| apisix.core.ohmlab.fr | apisix dashboard | Ingress — dies with APISIX |
| teleport.core.ohmlab.fr + wildcard | teleport | TLSRoute (passthrough) + Ingress |

Apps marked "define `gateway.routes`" are Ingress-only today: give them
`gateway.routes` entries in their instance values as part of their cutover
step (the HTTPRoute templates exist in every app chart). The legacy
`Ingress` objects (`className: apisix`) become dead config once APISIX is
gone — remove the `ingress:` blocks at decommission.

## Phase 0 — deploy Traefik alongside APISIX ✅ (this commit)

- [x] `traefik` catalog app (`argo-cd/apps/traefik/`): chart 41.0.1
      (Traefik v3.7.5), 2 replicas, PDB, spread across nodes, non-root,
      JSON access logs, ServiceMonitor, no phone-home.
- [x] `homelab-gateway-traefik` Gateway (kube-system) mirroring all APISIX
      listeners incl. teleport TLS passthrough; own HTTP→HTTPS redirect.
- [x] `enabled: "true"` in `instances/homelab/core.yaml` (syncWave 11).
- [x] `gateway.extraParentRefs` support in every app's HTTPRoute/TLSRoute
      template.
- [x] HAProxy template: SNI routing + `traefik_entrypoint_https` backend,
      inert while the migration vars are unset.
- [x] crowdsec: `crowdsecurity/traefik` collection + acquisition for
      `traefik/traefik-*` pods.

**Validation** (after ArgoCD syncs):

```sh
kubectl -n traefik get pods                    # 2/2 Running
kubectl -n kube-system get gateway homelab-gateway-traefik \
  -o jsonpath='{.status.conditions}'           # Accepted/Programmed True
kubectl get svc -n traefik traefik             # LB with ports 8080/8443
# svclb pods bind 8080/8443 on every node:
kubectl -n kube-system get pods -l svccontroller.k3s.cattle.io/svcname=traefik
# TLS handshake through the traefik path (from the LAN, any node IP):
curl -vk --resolve ohmlab.fr:8443:<node-ip> https://ohmlab.fr:8443/
# expect a valid wildcard cert + 404 (no routes attached yet)
```

## Phase 1 — migrate hostnames one at a time

Per hostname (start with **homepage `ohmlab.fr`**, lowest stakes):

1. **git**: in the app's instance values add
   ```yaml
   gateway:
     extraParentRefs:
     - name: homelab-gateway-traefik
   ```
   (Ingress-only apps: add the full `gateway:` block with `routes:` instead —
   copy the shape from `instances/homelab/values/tenant/gitea.yaml`.)
   Commit, push, wait for sync.
2. **verify attachment**: the route lists both gateways as accepted parents:
   ```sh
   kubectl -n <ns> get httproute <name> -o jsonpath='{.status.parents[*].parentRef.name}'
   ```
   and the hostname answers on the traefik path:
   `curl -sk --resolve <host>:8443:<node-ip> https://<host>:8443/ -o /dev/null -w '%{http_code}'`
3. **flip traffic**: add the hostname to `haproxy.traefikHosts` in
   `ansible/inventory/group_vars/gateway.yml`, then
   `ansible-playbook install.yml --tags haproxy` (gateway host only).
4. **verify + observe**: `curl -s https://<host>` from outside; check access
   logs `kubectl -n traefik logs deploy/traefik | tail`; leave it for a day
   before the next hostname if the app is stateful (sessions, SSO).
5. **rollback** (if needed): remove the hostname from `traefikHosts`, re-run
   the playbook — routes stay attached to both gateways, so this is instant.

Suggested order (blast-radius ascending):

- [ ] ohmlab.fr (homepage)
- [ ] monitoring.ohmlab.fr (grafana)
- [ ] longhorn.core.ohmlab.fr (add routes)
- [ ] gitops.core.ohmlab.fr + gitops-appset.core.ohmlab.fr (add routes)
- [ ] console.s3.ohmlab.fr + s3.ohmlab.fr (add routes; S3 clients!)
- [ ] vault.core.ohmlab.fr
- [ ] git.ohmlab.fr (gitea)
- [ ] mattermost.ohmlab.fr
- [ ] sso.core.ohmlab.fr (keycloak — every SSO login flows through it)
- [ ] `*.teleport.core.ohmlab.fr` + apex: TLSRoutes get `extraParentRefs`,
      then add `.teleport.core.ohmlab.fr` to `traefikHostSuffixes` and
      `teleport.core.ohmlab.fr` to `traefikHosts`.

## Phase 2 — decommission APISIX

Only after **every** hostname is on Traefik and stable:

- [ ] Flip port 80 + default: `haproxy.ingressDefault: traefik` (playbook).
      Public traffic no longer reaches APISIX at all.
- [ ] cert-manager: any ClusterIssuer with an `http01` solver must set
      `ingress.class: traefik` (check `values/core/cert-manager.yaml`);
      re-test a renewal (`cmctl renew <cert>` or wait for a solver Ingress
      to appear and resolve via traefik).
- [ ] Move Certificate ownership: apisix instance values
      `gateway.enabled: false` + traefik instance values
      `gateway.manageCertificate: true` — same commit. cert-manager adopts
      the existing secret; no re-issue.
- [ ] Routes: remove `extraParentRefs` everywhere and set
      `gateway.gatewayName: homelab-gateway-traefik` as the primary (one
      sweep commit); delete dead `ingress:` blocks (`className: apisix`).
- [ ] Disable the app: `enabled: "false"` for apisix in core.yaml.
      ⚠ Application deletion does NOT cascade (no resources-finalizer since
      2026-07-05) — clean up manually: `kubectl delete ns apisix`.
- [ ] Take over 80/443: traefik instance values
      `traefik.ports.web.exposedPort: 80` + `websecure.exposedPort: 443`,
      then on the gateway set `traefikHttpPort: 80`, `traefikHttpsPort: 443`,
      clear `traefikHosts`/`traefikHostSuffixes` and re-run the playbook
      (HAProxy config returns to its vanilla shape).
- [ ] crowdsec: drop the apisix acquisition + `crowdsecurity/nginx`
      collection from `argo-cd/apps/crowdsec/values.yaml`.
- [ ] Docs sweep: 04-infrastructure, 05-services, 08 (mark executed).

Expected gains: ~0.5–1 GiB RAM back (2 gateway pods vs 2+3 etcd+1
controller), one stateful component (etcd) and one credential surface
(admin API) removed.

## Phase 3 — optional hardening (post-migration)

- **PROXY protocol** end-to-end client IPs (today the in-cluster controller
  sees the gateway's IP): HAProxy `send-proxy-v2` on the traefik backends
  **and** `traefik.ports.{web,websecure}.proxyProtocol.trustedIPs:
  [192.168.1.0/24, 10.42.0.0/16]` must ship together — mismatched ends
  break all traffic. Test on 8443 before flipping 443.
- **CrowdSec bouncer middleware** (blocks banned IPs at the edge instead of
  only at the gateway host): traefik plugin
  `github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin` via
  `experimental.plugins` + a `Middleware` CR wired into
  `ports.websecure.http.middlewares`; LAPI key registered with
  `cscli bouncers add traefik` and delivered from Vault via VSO. Requires
  PROXY protocol first — without real client IPs it would ban the gateway.
