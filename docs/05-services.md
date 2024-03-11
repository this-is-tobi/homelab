# Services

## Gateway

### Haproxy

[HAProxy](https://www.haproxy.org/) is a free and open source software that provides a high availability load balancer and reverse proxy for TCP and HTTP-based applications that spreads requests across multiple servers.

Haproxy load-balances all incoming http and https traffic from the Internet (ports 80 and 443) via the master nodes, and also load-balances all Kubernetes api server traffic on the local network (port 6443). An ACL rule is defined to accept only local network IP address requests for the api server.

The web interface lets you view the health status of master nodes on both types of endpoints (server api and internet traffic).

### Pi-Hole

[Pi-hole](https://pi-hole.net/) is a Linux network-level advertisement and Internet tracker blocking application which acts as a DNS sinkhole and optionally a DHCP server, intended for use on a private network. It is designed for low-power embedded devices with network capability, such as the Raspberry Pi, but can be installed on almost any Linux machine.

Pi-hole has the ability to block traditional website advertisements as well as advertisements in unconventional places, such as smart TVs and mobile operating system advertisements.

Using the web interface, you can enable/disable ad and tracker blocking, add a list of domains to be blocked, and configure local network DNS settings (and DHCP if required). It is also possible to view statistics on blocked domains according to the privacy rules set.

### Wireguard

[WireGuard](https://www.wireguard.com/) is a communication protocol and free and open-source software that implements encrypted virtual private networks (VPNs), and was designed with the goals of ease of use, high speed performance, and low attack surface.

Wireguard's web interface lets you create / delete / activate / deactivate VPN users, download their configuration file and display the user's QrCode. With this user configuration file, a user can access the homelab network to perform an ssh connection to the bastion and then request the Kubernetes api server.

### Access

Gateway web interface services are deployed and accessible for admin purpose, they are available on local network at :

| Name                | Url                         |
| ------------------- | --------------------------- |
| Haproxy dashboard   | <http://192.168.1.99:8404>  |
| Pihole dashboard    | <http://192.168.1.99:5353>  |
| Wireguard dashboard | <http://192.168.1.99:51821> |

> *__Notes:__ Replace `192.168.1.99` with the gateway's ip address set in [hosts.yml](../ansible/inventory-example/hosts.yml).*

## Kubernetes

### Services

The following services are deployed in the cluster :

| Name                                                                              | Description                                     | Helm chart                                                                                                                                      |
| --------------------------------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| [Actions-runner-controller](https://github.com/actions/actions-runner-controller) | Github Actions runners controller               | [actions-runner-controller/actions-runner-controller](https://artifacthub.io/packages/helm/actions-runner-controller/actions-runner-controller) |
| [ArgoCD](https://argo-cd.readthedocs.io/en/stable/)                               | GitOps continuous delivery tool                 | [argo/argo-cd](https://artifacthub.io/packages/helm/argo/argo-cd)                                                                               |
| [Coder](https://coder.com/)                                                       | Remote selfhosted development environments      | [coder-v2/coder](https://artifacthub.io/packages/helm/coder-v2/coder)                                                                           |
| [Cert-manager](https://cert-manager.io/)                                          | Cloud native certificate management             | [cert-manager/cert-manager](https://artifacthub.io/packages/helm/cert-manager/cert-manager)                                                     |
| [Cloud-native-postgres](https://cloudnative-pg.io/)                               | Cloud native postgres database management       | [cnpg/cloudnative-pg](https://artifacthub.io/packages/helm/cloudnative-pg/cloudnative-pg)                                                       |
| [Dashy](https://github.com/Lissy93/dashy)                                         | Home dashboard                                  | -                                                                                                                                               |
| [Gitea](https://about.gitea.com/)                                                 | Private, Fast, Reliable DevOps Platform         | [gitea/gitea](https://artifacthub.io/packages/helm/gitea/gitea)                                                                                 |
| [Harbor](https://goharbor.io/)                                                    | Cloud native registry                           | [bitnami/harbor](https://artifacthub.io/packages/helm/bitnami/harbor)                                                                           |
| [Keycloak](https://keycloak.org)                                                  | Single Sign On service                          | [bitnami/keycloak](https://artifacthub.io/packages/helm/bitnami/keycloak)                                                                       |
| [Kubernetes-dashboard](https://github.com/kubernetes/dashboard)                   | Kubernetes dashboard                            | [k8s-dashboard/kubernetes-dashboard](https://artifacthub.io/packages/helm/k8s-dashboard/kubernetes-dashboard)                                   |
| [Longhorn](https://longhorn.io/)                                                  | Cloud native distributed block storage          | [longhorn/longhorn](https://artifacthub.io/packages/helm/longhorn/longhorn)                                                                     |
| [Mattermost](https://mattermost.com/)                                             | Chat service with file sharing and integrations | [mattermost/mattermost-team-edition](https://artifacthub.io/packages/helm/mattermost/mattermost-team-edition)                                   |
| [Minio](https://min.io/)                                                          | High Performance Object Storage                 | [bitnami/minio](https://artifacthub.io/packages/helm/bitnami/minio)                                                                             |
| [Outline](https://www.getoutline.com/)                                            | Share notes and wiki with your team             | [lrstanley/outline](https://artifacthub.io/packages/helm/lrstanley/outline)                                                                     |
| [Prometheus-stack](https://prometheus.io/)                                        | Open-source monitoring solution                 | [prometheus-community/kube-prometheus-stack](https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack)                   |
| [Sonarqube](https://www.sonarsource.com/products/sonarqube/)                      | Code quality analysis service                   | [sonarqube/sonarqube](https://artifacthub.io/packages/helm/sonarqube/sonarqube)                                                                 |
| [Sops](https://github.com/isindir/sops-secrets-operator)                          | Secret manager that decode on the fly           | [sops-secrets-operator/sops-secrets-operator](https://artifacthub.io/packages/helm/sops-secrets-operator/sops-secrets-operator)                 |
| [System-upgrade-controller](https://github.com/rancher/system-upgrade-controller) | K3S upgrade controller                          | -                                                                                                                                               |
| [Trivy-operator](https://aquasecurity.github.io/trivy-operator/latest/)           | Kubernetes-native security toolkit              | [aqua/trivy-operator](https://aquasecurity.github.io/helm-charts/)                                                                              |
| [Vault](https://www.vaultproject.io/)                                             | Secret management service                       | [hashicorp/vault](https://artifacthub.io/packages/helm/hashicorp/vault)                                                                         |

### Versions

To improve administrator experience, all services helm charts and versions can be managed thought the `groups_vars/services.yml` file for __core services only__.

Additional services are managed through gitops flow with sources available [here](../argocd/envs/production/application.yaml).

### Management

Additional services activation/deactivation is managed by Ansible directly in the [app of apps file](../argocd/envs/production/application.yaml), by commenting the blocks in the `.spec.sources` section.

### Access

Kubernetes services that are available through user interfaces are centralized on the [dashy](https://github.com/Lissy93/dashy) homepage, the full list is :

#### Admin

| Name               | Url                                |
| ------------------ | ---------------------------------- |
| ArgoCD *(admin)*   | <https://gitops.admin.domain.com>  |
| Longhorn *(admin)* | <http://longhorn.admin.domain.com> |
| Vault *(admin)*    | <https://vault.admin.domain.com>   |

#### Standard

| Name                 | Url                             |
| -------------------- | ------------------------------- |
| ArgoCD               | <https://gitops.domain.com>     |
| Coder                | <https://coder.domain.com>      |
| Dashy                | <https://domain.com>            |
| Gitea                | <https://git.domain.com>        |
| Grafana              | <https://monitoring.domain.com> |
| Harbor               | <https://registry.domain.com>   |
| Keycloak             | <https://sso.domain.com>        |
| Kubernetes-dashboard | <https://kube.domain.com>       |
| Mattermost           | <https://mattermost.domain.com> |
| Minio *- api*        | <https://s3.domain.com>         |
| Minio *- web*        | <https://minio.domain.com>      |
| Outline              | <https://outline.domain.com>    |
| SonarQube            | <http://sonarqube.domain.com>   |
| Vault                | <https://vault.domain.com>      |

> *__Notes:__ Replace `domain.com` by your own domain set in [all.yml](../ansible/inventory-example/group_vars/all.yml).*

### Single sign on

[Keycloak](https://keycloak.org/) is deployed as the cluster single sign on tool, it give access to various services accross the same account (*i.e: username / password pair*) to improve user experience.
On the other hand, keycloak can pass user groups and roles to control access level to theese services.

It is also usefull for admins to have a better control over homelab users and access, users can be manage connecting the keycloak interface (*cf: [keycloak service url](#kubernetes)*) with admin credentials (`keycloak.username` and `keycloak.password` can be found in admin vault under the keycloak secrets).

> Don't forget to select 'homelab' realm

By default an admin group is created to give admin access on each service that use keycloak sso registration, keycloak users that are not in the admin group get simple access.

Following services are connected through sso :
- ArgoCD
- Coder
- Harbor
- Gitea
- Grafana
- Minio
- Outline
- Sonarqube
- Vault

### Monitoring

The cluster itself and some services are monitored using [Prometheus](https://prometheus.io/) and [Grafana](https://grafana.com/), `ServiceMonitor` are enabled for Vault, Minio, Argocd and Trivy-operator to increase metrics coming from these applications.

Some dashboards are already delivered with the installation but more can be added in `argocd/apps/prometheus-stack/manifests`, they will be automatically loaded on Argocd synchronization. Already added dashboards are :

| Repository source                                                                                  | Grafana dashboard ID                                                                                          |
| -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| [k3s-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/k3s-dashboard.yaml)                 | 15282                                                                                                         |
| [kube-global-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/kube-global-dashboard.yaml) | 18283                                                                                                         |
| [kube-node-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/kube-node-dashboard.yaml)     | 15759                                                                                                         |
| [kube-ns-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/kube-ns-dashboard.yaml)         | 15758                                                                                                         |
| [kube-pod-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/kube-pod-dashboard.yaml)       | 15760                                                                                                         |
| [argocd-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/argocd-dashboard.yaml)           | 14584                                                                                                         |
| [gitea-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/gitea-dashboard.yaml)             | 17802                                                                                                         |
| [harbor-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/harbor-dashboard.yaml)           | *- ( [source](https://github.com/goharbor/harbor/blob/main/contrib/grafana-dashboard/metrics-example.json) )* |
| [minio-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/minio-dashboard.yaml)             | 13502                                                                                                         |
| [trivy-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/trivy-dashboard.yaml)             | 16337                                                                                                         |
| [vault-dashboard.yaml](../argocd/apps/prometheus-stack/manifests/vault-dashboard.yaml)             | 12904                                                                                                         |
