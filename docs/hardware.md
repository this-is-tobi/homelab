# Hardware

The machines this instance runs on, and the choices made for them. The generic requirements (operating systems, access, the install options) are in the ohmlab documentation.

## Equipment

- 9 x Raspberry Pi 4 model B, 8GB: the K3s nodes
- 1 x Raspberry Pi 4 model B, 4GB: the gateway
- 3 x TP-Link TL-SG105E switches
- 4 x 2TB HDD (HDTP320EK3AA), USB-attached to four of the workers

## Layout

The hosts and their roles are in [ansible/inventory/hosts.yml](../ansible/inventory/hosts.yml):

| Group   | Hosts                        | Notes                                                               |
| ------- | ---------------------------- | ------------------------------------------------------------------- |
| gateway | `pi-gw`                      | HAProxy (80, 443, 6443) in front of the cluster                     |
| masters | `pi0`, `pi3`, `pi4`          | K3s control plane and embedded etcd                                 |
| workers | `pi1`, `pi2`, `pi5` to `pi8` | `pi1`, `pi2`, `pi5` and `pi6` carry a disk (`additional_disk: true`) and run Longhorn |

## Operating system

The nodes run Debian 13 (trixie) on the Debian generic arm64 kernel (the opt-in `kernel-upgrade` Ansible tag), upgraded in place from Raspberry Pi OS (64-bit).

## Networking

The cluster runs Cilium with K3s's ServiceLB disabled. Traefik is exposed through a static `externalIPs` list, and the gateway's HAProxy forwards public 80/443 onto the node addresses.

It started on flannel and moved to Cilium one node at a time with ohmlab's `scripts/cilium-migrate-node.sh`.

## Storage

Longhorn uses the four USB disks. They are spinning disks without UAS or TRIM, so I/O peaks (snapshots, backups) are the cluster's main bottleneck.
