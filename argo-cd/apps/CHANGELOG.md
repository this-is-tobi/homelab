# Changelog

## [0.2.1](https://github.com/this-is-tobi/homelab/compare/catalog-v0.2.0...catalog-v0.2.1) (2026-10-10)


### Bug Fixes

* **deps:** update ghcr.io/this-is-tobi/homelab/ohmlab docker tag to v0.1.1 ([75f2013](https://github.com/this-is-tobi/homelab/commit/75f2013cced9a85926d95d1f72f55ababea52ea6))
* **deps:** update kube-prometheus-stack docker tag to v92.3.0 ([7a38bfb](https://github.com/this-is-tobi/homelab/commit/7a38bfb5f906e6c512d26d9a654dab3ed65fee88))

## [0.2.0](https://github.com/this-is-tobi/homelab/compare/catalog-v0.1.0...catalog-v0.2.0) (2026-10-09)


### Features

* **kyverno:** replace every ClusterPolicy and legacy exception with CEL policies ([1794f9d](https://github.com/this-is-tobi/homelab/commit/1794f9da2f2a8b15062f93e877600d6fc7a2caad))


### Bug Fixes

* **deps:** update dependency hashicorp/vault to v2.1.2 ([bc42eb6](https://github.com/this-is-tobi/homelab/commit/bc42eb682aced7bd9780dae0754d65512b6e335c))
* **deps:** update helm release alloy to v1.13.1 ([d07aaf2](https://github.com/this-is-tobi/homelab/commit/d07aaf22df45b7e2591be15488b2780893af05b7))
* **deps:** update helm release argo-cd to v10.10.2 ([fa23f1a](https://github.com/this-is-tobi/homelab/commit/fa23f1ac16236af543136cfc2e6187df4777f463))
* **deps:** update helm release argo-workflows to v2.0.12 ([f0a355f](https://github.com/this-is-tobi/homelab/commit/f0a355f1f55350295f5b2c6ce3e33aeb7b516bf0))
* **deps:** update helm release loki to v18.15.1 ([956cc0b](https://github.com/this-is-tobi/homelab/commit/956cc0bd9f164bfd1d2c33dedfa6bd0c6fdd1787))
* **deps:** update helm release traefik to v41.7.1 ([8849af6](https://github.com/this-is-tobi/homelab/commit/8849af61ec9ca666f7d06aa608b1c1d46c464387))
* **deps:** update keycloak docker tag to v0.21.46 ([7ddb817](https://github.com/this-is-tobi/homelab/commit/7ddb8176a854a8426442277f718809ecc367a4bb))
* **deps:** update kube-prometheus-stack docker tag to v92.2.0 ([6e5c247](https://github.com/this-is-tobi/homelab/commit/6e5c24757bfcd85b18d1521c7a3f56284a482093))
* **kyverno:** read the CEL policy metrics in the denial alert and the dashboard ([72a5905](https://github.com/this-is-tobi/homelab/commit/72a59057693d2f8e9f5d8c2363654b1b00a65398))

## 0.1.0 (2026-10-06)


### Features

* **actions-runner-controller:** deliver the GitHub App from Vault ([25830cd](https://github.com/this-is-tobi/homelab/commit/25830cd8b946be3490905c2fac0657ad129a07e1))
* **instance-manager:** take an app's chart from a named registry ([128d483](https://github.com/this-is-tobi/homelab/commit/128d48388550180eb051cd95b7321708abdf761f))
* **instance-manager:** take charts from a bundle catalog ([0d2d992](https://github.com/this-is-tobi/homelab/commit/0d2d992e0acf4af4d145c9750d1bcaf068d05bb1))


### Bug Fixes

* **actions-runner-controller:** key the runner values by the dependency aliases ([9de40e0](https://github.com/this-is-tobi/homelab/commit/9de40e0549b2f3633b110f77dee09551f9686f24))
* **example:** make the example Vault config agree with the chart defaults ([a7ac740](https://github.com/this-is-tobi/homelab/commit/a7ac740fdf4f683cb7fc308a369e981175d31334))
* **vso:** keep the whole Vault path out of every Secret the operator writes ([1642b88](https://github.com/this-is-tobi/homelab/commit/1642b88a80be1cb96bd736f70eca3adfded6e251))
