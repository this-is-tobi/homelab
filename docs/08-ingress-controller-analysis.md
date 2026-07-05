# Ingress controller analysis

> Decision record — written 2026-07, after the APISIX admin-key/etcd
> hardening and the Cilium phase-1 investigation. Re-evaluate when the
> constraints below change.

## Context and constraints

- **Hardware**: 9× Raspberry Pi 4 (arm64, 4-8 GB RAM). Memory is the scarce
  resource; every always-on pod counts. Kernel is now Debian trixie 6.12
  (52-bit VA — the old envoy/tcmalloc arm64 blocker is gone).
- **Traffic**: single-digit users, TLS-terminated web apps + a few TCP/SNI
  passthroughs (Teleport). Raw throughput is a non-issue; latency and
  memory footprint matter more than requests/second.
- **Security bar**: zero-trust posture, CrowdSec in the stack, cert-manager
  for certs, Keycloak for SSO, everything GitOps-managed. The gateway is the
  single internet-facing component — its attack surface and its
  secret-handling matter more than features.
- **History**: ingress-nginx is retired upstream (maintenance-only since
  March 2026) — staying is not an option. Cilium's first rollout caused an
  SSH lockout (BPF on eth0, see `argo-cd/apps/cilium/values.yaml`); phase-1
  config runs Cilium CNI-only with **zero BPF on physical interfaces**.
  APISIX is deployed today and was just hardened (Vault-managed admin key,
  mutual-TLS etcd).

## Candidates

| | APISIX (current) | Traefik v3 | HAProxy IC | Cilium Gateway | Envoy Gateway |
|---|---|---|---|---|---|
| Always-on pods | 2 gateway + 3 etcd + 1 controller (~0.7–1 GiB reserved) | 1–2 pods (~100–150 MiB each) | 1–2 pods (~50–100 MiB) | inside the CNI agent (no extra pods) | 1–2 envoy + 1 controller (~200–300 MiB) |
| Config state | **external etcd cluster** (stateful, holds TLS private keys) | Kubernetes API only (stateless) | Kubernetes API only | Kubernetes API only | Kubernetes API only |
| Gateway API | yes (ingress-controller v2) | yes, conformant since v3.2 | partial, two competing controllers | yes (needs kube-proxy replacement) | yes (reference implementation) |
| Language / CVE surface | C (nginx) + Lua plugin runtime + admin API | Go, memory-safe, no admin API | C, very mature, small surface | C++ (Envoy) embedded in CNI | C++ (Envoy), mature CVE process |
| CrowdSec integration | plugin (community) | **native bouncer middleware** | bouncer available | none | none |
| arm64 on RPi | works | works (K3s default — proven on this exact platform) | works | works since trixie kernel | works since trixie kernel |
| Ops sharp edges seen here | dead-config nesting gotcha, public default admin key, bitnami-legacy etcd, 6-pod footprint | — | config-reload complexity, ecosystem split | ingress tied to CNI lifecycle; requires phase-2 KPR (the risky part) | young operational story |

### Why each one is / isn't the pick

**APISIX** — powerful (rich plugin set, dynamic config), and now properly
hardened. But it is the *heaviest* option on this hardware by a factor of
five, and its architecture is a poor fit for GitOps: the etcd cluster is a
stateful store holding **reconstructible** data (the ingress-controller
re-populates it from Kubernetes resources) *plus* sensitive material
(SSL objects = private keys), and the admin API is an extra
credential-bearing control surface that already bit us once. Nothing this
cluster does needs APISIX's differentiators.

**Traefik v3** — the recommendation. Single stateless Go binary; all config
lives in the Kubernetes API where GitOps expects it; Gateway API conformant;
no admin API, no external store, no Lua runtime; native CrowdSec bouncer
middleware plugs into the existing stack; and it is the K3s default ingress,
i.e. battle-tested on precisely this hardware profile. Trade-off: fewer
gateway-level plugins than APISIX (irrelevant here — auth is at
Keycloak/app level) and raw throughput below nginx/haproxy (irrelevant at
homelab scale).

**HAProxy** — best raw performance and a tiny footprint, but that solves a
problem we don't have, and costs Gateway API maturity (two competing
controllers, partial support) and Kubernetes-ecosystem polish. Rejected.

**Cilium Gateway** — architecturally elegant (ingress collapses into the
CNI, no extra pods at all) and the strongest *eventual* security story
(eBPF L3–L7 policy + WireGuard node encryption). But it requires
kube-proxy replacement — exactly the phase-2 step deliberately deferred
after the SSH lockout — and it couples the internet-facing data plane to
the CNI agent lifecycle: a Cilium bug or upgrade then risks pod networking
*and* all ingress at once. Revisit only after phase-2 KPR has run stably
behind the watchdog for a meaningful period.

**Envoy Gateway** — solid runner-up (CNCF reference implementation, mature
CVE handling). Heavier than Traefik on memory, younger operationally, and
no CrowdSec story. Choose it if Envoy-ecosystem alignment ever matters;
otherwise Traefik wins on footprint and fit.

## Decision

1. **Now**: keep APISIX. It was just hardened; churning the only
   internet-facing component twice in one quarter is worse than its
   footprint. No action.
2. **Next**: migrate to **Traefik v3** as the standing ingress + Gateway
   API implementation. Migration is low-risk and incremental: deploy
   Traefik as a second catalog app on its own LoadBalancer IP, move one
   hostname at a time (cert-manager secrets are controller-agnostic), then
   disable APISIX and drop its etcd — freeing ~0.5–1 GiB across the
   cluster and deleting a stateful component.
3. **Later, optional**: if Cilium phase-2 (kube-proxy replacement) ships
   and proves stable, re-evaluate Cilium Gateway to remove even the
   Traefik pods — explicitly weighing the CNI/ingress blast-radius
   coupling documented above.

Do **not** maintain multiple ingress options as first-class choices: every
additional option multiplies values files, docs and upgrade testing. The
catalog keeps `enabled: "false"` entries (ingress-nginx today, apisix after
the migration) only as escape hatches, not supported paths.
