# Services

## Gateway

Gateway web interface services are deployed and accessible for admin purpose, they are available on local network at :

| Name              | Url                                |
| ----------------- | ---------------------------------- |
| Haproxy dashboard | <http://haproxy.domain.local:8404> |

## Kubernetes

The following services are deployed in the cluster :

| Name                                                                              | Description                                     | Helm chart                                                                                                                                      |
| --------------------------------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| [Actions-runner-controller](https://github.com/actions/actions-runner-controller) | Github Actions runners controller               | [actions-runner-controller/actions-runner-controller](https://artifacthub.io/packages/helm/actions-runner-controller/actions-runner-controller) |
| [ArgoCD](https://argo-cd.readthedocs.io/en/stable/)                               | GitOps continuous delivery tool                 | [argo/argo-cd](https://artifacthub.io/packages/helm/argo/argo-cd)                                                                               |
| [Cert-manager](https://cert-manager.io/)                                          | Cloud native certificate management             | [cert-manager/cert-manager](https://artifacthub.io/packages/helm/cert-manager/cert-manager)                                                     |
| [Cloud-native-postgres](https://cloudnative-pg.io/)                               | Cloud native postgres database management       | [cnpg/cloudnative-pg](https://artifacthub.io/packages/helm/cloudnative-pg/cloudnative-pg)                                                       |
| [Dashy](https://github.com/Lissy93/dashy)                                         | Home dashboard                                  | -                                                                                                                                               |
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

To improve administrator experience, all services helm charts and versions can be managed thought the `groups_vars/services.yml` file.

### Access

Kubernetes services that are available through user interfaces are centralized on the [dashy](https://github.com/Lissy93/dashy) homepage but the full list can be found here :

| Name                 | Url                                |
| -------------------- | ---------------------------------- |
| ArgoCD *(admin)*     | <https://gitops.admin.domain.com>  |
| ArgoCD               | <https://gitops.domain.com>        |
| Dashy                | <https://domain.com>               |
| Grafana              | <https://monitoring.domain.com>    |
| Harbor               | <https://registry.domain.com>      |
| Keycloak             | <https://sso.domain.com>           |
| Kubernetes-dashboard | <https://kube.domain.com>          |
| Longhorn             | <http://longhorn.admin.domain.com> |
| Mattermost           | <https://mattermost.domain.com>    |
| Minio *- api*        | <https://s3.domain.com>            |
| Minio *- web*        | <https://minio.domain.com>         |
| Outline              | <https://outline.domain.com>       |
| SonarQube            | <http://sonarqube.domain.com>      |
| Vault *(admin)*      | <https://vault.admin.domain.com>   |
| Vault                | <https://vault.domain.com>         |

> *__Notes:__ Replace `domain.com` by your own domain.*

### Single sign on

[Keycloak](https://keycloak.org/) is deployed as the cluster single sign on tool, it give access to various services accross the same account (*i.e: username / password pair*) to improve user experience.
On the other hand, keycloak can pass user groups and roles to control access level to theese services.

It is also usefull for admins to have a better control over homelab users and access, users can be manage connecting the keycloak interface (*cf: [keycloak service url](#kubernetes)*) with admin credentials (`keycloak.username` and `keycloak.password` can be found in admin vault under the keycloak secrets).

> Don't forget to select 'homelab' realm

By default a group is created for each service that use keycloak sso registration, add user to group to grant access level for the given service.

Following services are connected through sso :
- ArgoCD
- Harbor
- Grafana
- Minio
- Outline
- Sonarqube
- Vault

### Monitoring

The cluster itself and some services are monitored using [Prometheus](https://prometheus.io/) and [Grafana](https://grafana.com/), `ServiceMonitor` are enabled for Vault, Minio, Argocd and Trivy-operator to increase metrics coming from these applications.

Some dashboards are already delivered with the installation but more can be added in `argocd/apps/prometheus-stack/manifests`, they will be automatically loaded on Argocd synchronization.
