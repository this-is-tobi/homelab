# The same policy with deletion allowed (ohmlab.controller.allowDelete). The
# controller only ever calls DELETE on the metadata path, which removes every
# version and the metadata, so delete is granted there and nowhere else.
path "homelab/data/platforms/+/+/*" {
  capabilities = ["create", "update", "read"]
}
path "homelab/metadata/platforms/+/+/*" {
  capabilities = ["read", "update", "delete"]
}
