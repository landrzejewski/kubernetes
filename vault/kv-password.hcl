# kv-password.hcl
# Grants full KV-v2 capabilities under secret/data/passwords/*

path "secret/data/passwords/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/passwords/*" {
  # needed for listing keys under secret/data/passwords
  capabilities = ["list"]
}

# Optionally, if you want to allow kv delete-metadata operations:
# path "secret/delete/passwords/*" {
#   capabilities = ["delete"]
# }