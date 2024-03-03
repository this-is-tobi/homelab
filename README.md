# Homelab :alembic:

This project aims to build a homelab for personal testing on infrastructure, development, CI/CD, etc...

It provides a complete configuration with common web services using ansible as a deployment tool for both infrastructure  (gateway, bastion and [k3s](https://k3s.io) cluster) and applications running mainly in Kubernetes.

It is a quick starting point for simple infrastructure needs or for testing various tools such as monitoring, alerting, automated deployment, security testing, etc...

## Documentation

__Website:__ <https://this-is-tobi.com/homelab/introduction.html>.

__Table of Contents__ *- md sources*:
- [Compatibility](./docs/02-compatibility.md)
- [Infrastructure](./docs/03-infrastructure.md)
- [Installation](./docs/04-installation.md)
- [Services](./docs/05-services.md)
- [Projects](./docs/06-projects.md)
- [Cheat sheet](./docs/07-cheat-sheet.md)


## Quickstart

Make sure you meet all [prerequisites](./installation#prerequisites).

Setup directory :
```sh
# Clone the repository
git clone --depth 1 https://github.com/this-is-tobi/homelab.git && cd ./homelab && rm -rf ./.git

# Copy inventory example to inventory
cp -R ./ansible/inventory-example ./ansible/inventory
```

Setup inventory values :
- [host.yml](../ansible/inventory/hosts.yml)
- [all.yml](../ansible/inventory/group_vars/all.yml)
- [bastion.yml](../ansible/inventory/group_vars/bastion.yml)
- [gateway.yml](../ansible/inventory/group_vars/gateway.yml)
- [k3s.yml](../ansible/inventory/group_vars/k3s.yml)
- [services.yml](../ansible/inventory/group_vars/services.yml)


Install homelab :
```sh
# Install infra
./run.sh -p ./ansible/infra.yml -u -k

# Set kube context
kubectl config set-context homelab

# Install services
./run.sh -p ./ansible/services.yml
```
