# Projects

Projects informations is stored in Vault under the key `secret/admin/projects`, these informations is evaluated by the [ansible playbook](../infra/ansible/projects.yml) to create the appropriate namespaces, keycloak mapping, etc... for each type of service available in the platform.

## Argocd

An `appProject` Argocd is created for each project with the key `argocd.enabled: true`, each project is mapped to the project's Keycloak group.
Argocd is deployed with the [argocd-vault-plugin](https://argo-cd-vault-plugin.readthedocs.io/en/stable/) which allows Vault secrets to be used in manifests.

Argocd applications require you to specify the name of the secret containing the connection information on the project's Vault namespace, and should be deployed according to the following example:

```yaml
project: example-project
source:
  repoURL: 'https://github.com/this-is-tobi/example-project.git'
  path: ./helm
  targetRevision: main
  plugin:
    env:
      - name: AVP_SECRET
        value: <avp_secret_name> # Available in Vault under the key `secret.<project_name>.vault.avpSecretName`
      - name: ARGOCD_ENV_HELM_VALUES
        value: |
          ingress: {}
          ...
destination:
  server: 'https://kubernetes.default.svc'
  namespace: example-project
syncPolicy:
  automated: {}
```

## Vault

Each project with the key `vault.enabled: true` get a namespace in the key value engine `secret/` with the appropriate policy mapped to the project's Keycloak group.
In addition, a secret including a token whose access is restricted to the project's Vault namespace is created, enabling Argocd to retrieve Vault secrets. Manifests must include the appropriate secret name in the kubernetes manifests, as shown in the [example](https://argo-cd-vault-plugin.readthedocs.io/en/stable/config/#using-kubernetes-secrets-for-supplying-avp-configuration) of the argocd-vault plugin.

## Sonarqube

Projects with the key `sonarqube.enabled : true` benefit from the creation of a Sonarqube project mapped to the project's keycloak group, and a private key is generated to transmit code analyses to the sonar server.

## Minio

The key `minio.enabled: true` is used to create an s3 bucket dedicated to the project, along with the appropriate access mapping to the project's Keycloak group.
By default, a 10GB quota is applied to the bucket.

## Actions Runner Controller

For each projects with the key `arc.enabled: true`, a set of Github Actions runners is deployed following the settings in `arc.runners`.
