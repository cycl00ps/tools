ui             = true
disable_mlock  = true

storage "raft" {
  path    = "/openbao/data"
  node_id = "node1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr     = "http://127.0.0.1:9092"
cluster_addr = "http://127.0.0.1:8201"
