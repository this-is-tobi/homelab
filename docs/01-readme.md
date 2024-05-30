# Homelab :alembic:

This project aims to build a homelab for personal testing on infrastructure, development, CI/CD, etc...

It provides a complete configuration with common web services using ansible as a deployment tool for both infrastructure  (gateway, bastion and [k3s](https://k3s.io) cluster) and applications running mainly in Kubernetes.

It is a quick starting point for simple infrastructure needs or for testing various tools such as monitoring, alerting, automated deployment, security testing, etc...

## Quickstart

Make sure all [prerequisites](./installation.md#prerequisites) are met.

__Setup directory:__
```sh
# Clone the repository
git clone --depth 1 https://github.com/this-is-tobi/homelab.git && cd ./homelab && rm -rf ./.git && git init

# Copy inventory example to inventory
cp -R ./infra/ansible/inventory-example ./infra/ansible/inventory
cp -R ./kubernetes/ansible/inventory-example ./kubernetes/ansible/inventory
```

### Infra

__Setup inventory:__
- [host.yml](../infra/ansible/inventory-example/hosts.yml)
- [all.yml](../infra/ansible/inventory-example/group_vars/all.yml)
- [bastion.yml](../infra/ansible/inventory-example/group_vars/bastion.yml)
- [gateway.yml](../infra/ansible/inventory-example/group_vars/gateway.yml)
- [k3s.yml](../infra/ansible/inventory-example/group_vars/k3s.yml)

__Install:__

```sh
# Install infra
./run.sh -p ./infra/ansible/install.yml -u -k
```

### Kubernetes

__Setup inventory:__
- [services.yml](../kubernetes/ansible/inventory-example/group_vars/services.yml)

__Install:__

```sh
# Set kube context
kubectl config set-context homelab

# Install services
./run.sh -p ./kubernetes/ansible/services.yml -u
```
