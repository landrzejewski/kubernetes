storage "raft" {
  path    = "/home/k8s/vault-db"
  node_id = "node1"

  retry_join {
      leader_api_addr = "http://0.0.0.0:8201"
  }
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_disable   = true   # **In production, use proper TLS certificates**
}

api_addr = "http://0.0.0.0:8200"
cluster_addr = "http://0.0.0.0:8201"

ui = true   # Enable the built-in UI
