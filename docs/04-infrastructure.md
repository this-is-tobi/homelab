# Infrastructure

![architecture](images/home.drawio.png)

## Gateway

A host is configured as the gateway to the local network (*i.e handle all incoming traffic*). It runs various services deployed with systemd :

- [Crowdsec](https://www.crowdsec.net/) for security purpose as it acts as a community firewall.
- [Haproxy](https://www.haproxy.org/) for loadbalancing all incoming external requests (*ports 80 & 443*) to the k3s cluster and loadbalancing k3s api server (*port 6443*).
- [PiHole](https://pi-hole.net/) for advertisements filtering.
- [Wireguard](https://www.wireguard.com/) for external access to the local network (*i.e from internet*). VPN clients could be add using the web interface (see. services section).

## Bastion

A host is configured as the bastion to access kubernetes ressources. As previously mentioned, a wireguard profile conf is generated for every `bastionUsers` set in [group_vars/all.yml](../infra/ansible/inventory-example/group_vars/all.yml).

Bastion is available on the local network using ssh :

1. Connect to the vpn using the wireguard user profile conf.
2. Connect to the bastion using `ssh <username>@<bastion_ip> -i <ssh_key>`.

Set `setup: true` on the user object to install common packages and default zsh configuration.

## K3S cluster

Some hosts are configrured to run [k3s](https://k3s.io) (*Lightweight Kubernetes*) with the following roles :
- 3 x master nodes
- 5 x worker nodes

The cluster comes with k3s integrated [klipper](https://github.com/k3s-io/klipper-lb) loadbalancer ([traefik](https://traefik.io/) ingressController is disabled and installed manually).
For convenience, [system-upgrade-controller](https://github.com/rancher/system-upgrade-controller) is deployed to perform an automatic k3s upgrade on each node by using two plans (one for masters and the other one for workers).

[Longhorn](https://longhorn.io/) is used to deliver distributed block storage accross kubernetes, it will enroll all servers tagged `additional_disk: true` in [inventory/hosts.yml](../infra/ansible/inventory-example/hosts.yml).
