# Services

## Gateway

Gateway web interface services are deployed and accessible for admin purpose, they are available on local network at :

| Name               | Url                                 |
| ------------------ | ----------------------------------- |
| Crowdsec dashboard | <http://crowdsec.domain.local:3000> |
| Haproxy dashboard  | <http://haproxy.domain.local:8404>  |

## Kubernetes

The following services are deployed in the cluster :

| Name                                                                              | Description                                     | Helm chart                                                                                                                                      |
| --------------------------------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| [Actions-runner-controller](https://github.com/actions/actions-runner-controller) | Github Actions runners controller               | [actions-runner-controller/actions-runner-controller](https://artifacthub.io/packages/helm/actions-runner-controller/actions-runner-controller) |
| [ArgoCD](https://argo-cd.readthedocs.io/en/stable/)                               | GitOps continuous delivery tool                 | [bitnami/argo-cd](https://artifacthub.io/packages/helm/bitnami/argo-cd)                                                                         |
| [Cert-manager](https://cert-manager.io/)                                          | Cloud native certificate management             | [cert-manager/cert-manager](https://artifacthub.io/packages/helm/cert-manager/cert-manager)                                                     |
| [Cloud-native-postgres](https://cloudnative-pg.io/)                               | Cloud native postgres database management       | [cnpg/cloudnative-pg](https://artifacthub.io/packages/helm/cloudnative-pg/cloudnative-pg)                                                       |
| [Dashy](https://github.com/Lissy93/dashy)                                         | Home dashboard                                  | -                                                                                                                                               |
| [Grafana](https://grafana.com/)                                                   | Observability dashboards                        | [bitnami/grafana](https://artifacthub.io/packages/helm/bitnami/grafana)                                                                         |
| [Harbor](https://goharbor.io/)                                                    | Cloud native registry                           | [bitnami/harbor](https://artifacthub.io/packages/helm/bitnami/harbor)                                                                           |
| [Keycloak](https://keycloak.org)                                                  | Single Sign On service                          | [bitnami/keycloak](https://artifacthub.io/packages/helm/bitnami/keycloak)                                                                       |
| [Kubernetes-dashboard](https://github.com/kubernetes/dashboard)                   | Kubernetes dashboard                            | [k8s-dashboard/kubernetes-dashboard](https://artifacthub.io/packages/helm/k8s-dashboard/kubernetes-dashboard)                                   |
| [Longhorn](https://longhorn.io/)                                                  | Cloud native distributed block storage          | [longhorn/longhorn](https://artifacthub.io/packages/helm/longhorn/longhorn)                                                                     |
| [Mattermost](https://mattermost.com/)                                             | Chat service with file sharing and integrations | [mattermost/mattermost-operator](https://artifacthub.io/packages/helm/mattermost/mattermost-operator)                                           |
| [Minio](https://min.io/)                                                          | High Performance Object Storage                 | [bitnami/minio](https://artifacthub.io/packages/helm/bitnami/minio)                                                                             |
| [Prometheus](https://prometheus.io/)                                              | Open-source monitoring solution                 | [bitnami/kube-prometheus](https://artifacthub.io/packages/helm/bitnami/kube-prometheus)                                                         |
| [System-upgrade-controller](https://github.com/rancher/system-upgrade-controller) | K3S upgrade controller                          | -                                                                                                                                               |
| [Vault](https://www.vaultproject.io/)                                             | Secret management service                       | [hashicorp/vault](https://artifacthub.io/packages/helm/hashicorp/vault)                                                                         |

### Versions

To improve administrator experience, all services helm charts and versions can be managed thought the `groups_vars/clusters.yml` file.

### Access

Kubernetes services that are available through user interfaces are centralized on the [dashy](https://github.com/Lissy93/dashy) homepage but the full list can be found here :

| Name                 | Url                             |
| -------------------- | ------------------------------- |
| ArgoCD               | <https://gitops.domain.com>     |
| Dashy                | <https://domain.com>            |
| Grafana              | <https://monitoring.domain.com> |
| Harbor               | <https://registry.domain.com>   |
| Keycloak             | <https://sso.domain.com>        |
| Kubernetes-dashboard | <https://console.domain.com>    |
| Longhorn             | <http://longhorn.domain.local>  |
| Mattermost           | <https://mattermost.domain.com> |
| Minio *- api*        | <https://api.s3.domain.com>     |
| Minio *- web*        | <https://s3.domain.com>         |
| Traefik              | <http://traefik.domain.local>   |
| Vault                | <http://vault.domain.com>       |

> *__Notes:__ Replace `domain.com` by your own domain.*

### Single sign on

[Keycloak](http://keycloak.org/) is deployed as the cluster single sign on tool, it give access to various services accross the same account (*i.e: username / password pair*) to improve user experience.
On the other hand, keycloak can pass user groups and roles to control access level to theese services.

It is also usefull for admins to have a better control over homelab users and access, users can be manage connecting the keycloak interface (*cf: [keycloak service url](#kubernetes)*) with admin credentials (`services.keycloak.username` and `services.keycloak.password` can be found in [group_vars/cluster.yml](../ansible/inventory-example/group_vars/cluster.yml) file).

> Don't forget to select 'homelab' realm

By default a group is created for each service that use keycloak sso registration, add user to group to grant access level for the given service.

Following services are connected through sso :
- ArgoCD
- Harbor
- Grafana
- Minio
- Vault
