variable "name" {
  type        = string
  description = "Cluster name prefix."
}

variable "region" {
  type        = string
  description = "AWS region (used for locality)."
}

variable "dns_zone" {
  type        = string
  description = "Base DNS zone for Cockroach node hostnames"
}

variable "azs" {
  type        = list(string)
  description = "Availability zones in this region."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets to spread nodes across."
}

variable "security_group_id" {
  type        = string
}

variable "nodes_per_region" {
  type        = number
  description = "Number of Cockroach nodes to deploy in this region."
}

variable "instance_type" {
  type = string
}

variable "disk_size_gb" {
  type        = number
  description = "Size of CockroachDB data disk (GB)"
}

variable "disk_type" {
  type        = string
  default     = "gp3"
}

variable "disk_iops" {
  type        = number
  default     = null
}

variable "disk_throughput" {
  type        = number
  default     = null
}

variable "ssh_key_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "cockroach_version" {}
variable "architecture" { default = "amd64" }

variable "vm_user" {}
variable "ssh_key" {}
