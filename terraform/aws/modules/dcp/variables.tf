variable "name" {}
variable "region" {}
variable "subnet_id" {}
variable "security_group_id" {}
variable "architecture" { default = "amd64" }
variable "instance_type" {}
variable "ssh_key_name" {}
variable "vm_user" {}
variable "ssh_key" {}

variable "backend_nodes" {
  type = list(string) # private IPs of regional HAProxy → Cockroach
}

variable "tags" {
  type = map(string)
  default = {}
}

# DCP specifics
variable "ha_node_count" {
  type = number
  default = 2
}
variable "pgb_port" {
  type = number
  default = 5432
}
variable "db_port"  {
  type = number
  default = 26257
}
variable "dns_zone" {
  type = string
}
