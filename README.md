# homelab

The instance of [ohmlab](https://github.com/this-is-tobi/ohmlab) that runs my own cluster: what is deployed, with which values, on which machines.

ohmlab provides the charts, the bootstrap chart, the controller and the provisioning roles. This repository only holds what is specific to this cluster.

## Layout

| Path                          | Purpose                                                                                       |
| ----------------------------- | --------------------------------------------------------------------------------------------- |
| `argo-cd/instances/homelab/`  | The instance: `instance.yaml`, the `core.yaml` and `tenant.yaml` catalogs, and `values/{core,tenant}/<app>.yaml` |
| `ansible/inventory/`          | The hosts and the variables of the provisioning roles (`vault.yml` is encrypted with ansible-vault) |
| [docs/hardware.md](docs/hardware.md) | The machines and the choices made for them                                            |

## How the cluster reads it

The root manager of the cluster's Argo CD takes its charts from the ohmlab repository and its values from this one (`rootManager.repoURL.sources` and `rootManager.repoURL.values` in `values/core/ohmlab.yaml`). A change merged here is applied by Argo CD; nothing else needs to run.

## Bootstrap

From an ohmlab checkout, with the cluster's context selected:

```sh
ARGOCD_ADMIN_PASSWORD=<choose-a-password> ./run.sh -b homelab -i <path to this repository>/argo-cd/instances
```

## Checks

Pull requests run the product's instance checks (`validate-instance.yml`: Vault access, VaultSeeds, VSO isolation), gitleaks on the new commits and the commit message lint. `ci-status` is the check to require.
