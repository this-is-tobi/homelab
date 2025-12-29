# Homelab :alembic:

This project aims to build a homelab for personal testing on infrastructure, development, CI/CD, etc...

It provides a complete configuration with common web services using:
- **Ansible** for infrastructure deployment (gateway and [k3s](https://k3s.io) cluster)
- **GitOps** (ArgoCD) for Kubernetes applications deployment

It is a quick starting point for simple infrastructure needs or for testing various tools such as monitoring, alerting, automated deployment, security testing, etc...

## Quickstart

Make sure all prerequisites are met (check the installation section if needed).

__Setup directory:__
```sh
# Clone the repository
git clone --depth 1 https://github.com/this-is-tobi/homelab.git && cd ./homelab && rm -rf ./.git && git init

# Copy inventory example to inventory
cp -R ./ansible/inventory-example ./ansible/inventory
```

### Infrastructure

__Setup inventory:__
- [hosts.yml](../ansible/inventory-example/hosts.yml)
- [all.yml](../ansible/inventory-example/group_vars/all.yml)
- [gateway.yml](../ansible/inventory-example/group_vars/gateway.yml)
- [k3s.yml](../ansible/inventory-example/group_vars/k3s.yml)

__Install:__
```sh
# Deploy gateway and K3s cluster, fetch kubeconfig
./run.sh -p ./ansible/install.yml -u -k
```

### Kubernetes Services (GitOps)

__Setup configuration:__
- Enable/disable apps in [./argo-cd/core/instances/homelab/production.json](../argo-cd/core/instances/homelab/production.json)
- Configure values in [./argo-cd/core/values/homelab/](../argo-cd/core/values/homelab/)

__Install:__
```sh
# Set kubectl context
kubectl config use-context homelab

# Bootstrap ArgoCD
./run.sh -b

# Apply core services (Longhorn, Vault, Cert-Manager, etc.)
./run.sh -c homelab

# Apply platform services (Keycloak, Gitea, Harbor, etc.)
./run.sh -s homelab
```
