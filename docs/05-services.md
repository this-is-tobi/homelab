# Services

## Gateway

Gateway web interface services are deployed and accessible for admin purpose, they are available on local network at :

| Name               | Url                                 |
| ------------------ | ----------------------------------- |
| Crowdsec dashboard | <http://crowdsec.domain.local:3000> |
| Haproxy dashboard  | <http://haproxy.domain.local:8404>  |

## Kubernetes

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
| Minio *- api*        | <https://api.s3.domain.com>     |
| Minio *- web*        | <https://s3.domain.com>         |
| Traefik              | <http://traefik.domain.local>   |
| Vault                | <http://vault.domain.com>       |

### Single sign on

[Keycloak](http://keycloak.org/) is deployed as the cluster single sign on tool, it give access to various services accross the same account (*i.e: username / password pair*) to improve user experience.
On the other hand, keycloak can pass user groups and roles to control access level to theese services.

It is also usefull for admins to have a better control over homelab users and access, users can be manage connecting the keycloak interface (*cf: [keycloak service url](#kubernetes)*) with admin credentials (`keycloak_username` and `keycloak_password` can be found in [group_vars/cluster.yml](../ansible/inventory-example/group_vars/cluster.yml) file).

> Don't forget to select 'homelab' realm

By default a group is created for each service that use keycloak sso registration, add user to group to grant access level for the given service.

Following services are connected through sso :
- ArgoCD
- Harbor
- Grafana
- Minio