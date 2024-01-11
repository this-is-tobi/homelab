# Installation

The whole installation is performed with [ansible](https://www.ansible.com/) so it is required to install it on the computer that will run playbooks. Also, ssh access to all hosts need to be setup.

> __*Notes*__:
>
> *Don't forget to replace `domain.com` with the appropriate domain. This can be setup in the the [all.yml](../ansible/inventory-example/group_vars/all.yml) file.*

## Prerequisites

For convenience, it is recommended to do these prerequisite steps :

```sh
# Add gateway into /etc/hosts in case they are deployed with local domain
[ ! $(sudo grep -q "192.168.0.110" /etc/hosts) ] && sudo sh -c "echo $'\n# Homelab\n192.168.0.110   crowdsec.domain.local haproxy.domain.local longhorn.domain.local traefik.domain.local' >> /etc/hosts"

# Copy inventory example to inventory
cp -R ./ansible/inventory-example ./ansible/inventory
```

Because crowdsec is used as the firewall, it is required to [create an account](https://app.crowdsec.net/) to share attack detection on the local network with the community as the community share it with us.

## Settings

Update the [hosts file](../ansible/inventory-example/hosts.yml) and [group_vars files](../ansible/inventory-example/group_vars/) to provide the appropriate infra and services settings.

To create user access to the bastion, it is required to provide their informations in the `groups_vars/all.yml` file :
- Set `setup: true` to setup the working environment for the given user
- Add users ssh public key following the file structure `./secrets/ssh/<bastion_username>.pub`, this will add the appropriate key in the matching bastion user `authorized_keys`.

> __*Notes*__:
>
> *During setup, every password, token and so on are randomly generated and stored into kubernetes secrets / vault secrets.*

## Deploy

Two playbooks are available, one for [infrastructure](../ansible/infra.yml) installation and another one for [services](../ansible/services.yml) installation.
Various tags are available in the playbooks (*for more details, take a look at the files*), it allows to launch only some part of the installation, the main ones are :

__Infra :__
```sh
# Deploy bastion
./run.sh -p ./ansible/infra.yml -t bastion

# Deploy gateway
./run.sh -p ./ansible/infra.yml -t gateway

# Deploy cluster
./run.sh -p ./ansible/infra.yml -t k3s
```

__Services :__

```sh
# Deploy kubernetes services
./run.sh -p ./ansible/services.yml

# Deploy only core services
./run.sh -p ./ansible/services.yml -t core

# Deploy only platform services
./run.sh -p ./ansible/services.yml -t additional

# Deploy only keycloak
./run.sh -p ./ansible/services.yml -t keycloak
```

> __*Notes*__:
>
> *By default tag `all` is used so every roles are played on playbooks launch.*
> *Multiple tags can be passed as follows :* `./run.sh -p ./ansible/infra.yml -t gateway,k3s`
>
> *First gateway init can take a long time to run because of openvpn key genereration (5-10min).*

## Destroy

It is possible to cleanly detroy the k3s cluster by running :

```sh
# Destroy cluster
./run.sh -p ./ansible/infra.yml -t k3s-destroy
```

## Kubernetes services

Kubernetes services are deployed within 2 steps, the first one deploy core services that are needed to deploy one or more platforms, core services are composed of :
- __Longhorn__ *- storage management in the cluster.*
- __Traefik__ *- ingress controler to expose services.*
- __Cert Manager__ *- certificate management for tls.*
- __Vault__ *- secret management for services deployments.*
- __Argocd__ *- deployment management for services deployments.*

Other services follow the gitops workflow, they are configured through files stored in a Git repository that is watched by Argocd.
An `applicationSet` is responsible to deploy an `app of apps` for each environement (or platform) wanted to be spin up, then the app of apps will deploy all others services with their dependencies by reading secrets into Hashicorp Vault.

![gitops-01](images/gitops-01.drawio.png)

The next step would be to deploy each platform environment to a dedicated cluster as described in the following schema.

![gitops-02](images/gitops-02.drawio.png)

## Notes

At the moment, `mattermost` and `outline` images are not `arm64` compatible so their deployment are using custom mirror image with compatibility (see. [this repo](https://github.com/this-is-tobi/multiarch-mirror) and and associated Argocd applications).

Every services could be disabled by commenting its declaration in the [service playbook](../ansible/services.yml) and in the Argocd [app of apps](../argocd/envs/production/application.yaml).
