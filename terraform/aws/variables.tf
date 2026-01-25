variable "project_name" {
  type    = string
  default = "crdb-dcp-test"
}

variable "dns_zone" {
  type        = string
  description = "Private DNS zone used for Cockroach nodes"
}

variable "public_zone_id" {
  type        = string
  description = "Route53 public hosted zone ID (optional). If set, create public db/pgb records."
  default     = ""
}

variable "enabled_regions" {
  type        = list(string)
  description = "US regions to deploy infrastructure into."
  default     = ["us-east-1", "us-east-2", "us-west-2"]

  validation {
    condition = alltrue([
      for r in var.enabled_regions :
      contains(
        ["us-east-1", "us-east-2", "us-west-1", "us-west-2"],
        r
      )
    ])
    error_message = "enabled_regions must be valid US AWS regions."
  }
}

variable "vpc_cidrs" {
  type = map(string)
  description = "VPC CIDRs per region."
  default = {
    us-east-1 = "10.10.0.0/16"
    us-east-2 = "10.20.0.0/16"
    us-west-1 = "10.30.0.0/16"
    us-west-2 = "10.40.0.0/16"
  }
}

variable "ssh_ip_range" {
  type    = string
}

variable "project_tags" {
  type = map(string)
  default = {
    Project = "jsonb-vs-text"
  }
}


############################
# Cluster shape
############################

variable "nodes_per_region" {
  type        = number
  description = "Number of CockroachDB nodes per enabled region."
  default     = 1
}

variable "az_count" {
  type        = number
  description = "Max AZs per region to spread nodes across."
  default     = 1
}

############################
# CockroachDB
############################

variable "cockroach_version" {
  type        = string
  description = "CockroachDB version to install."
  default     = "25.4.3"
}

variable "cluster_profile_name" {
  description = "Which named cluster profile to deploy"
  type        = string
  default     = "m6a-2xlarge"
}

variable "cluster_defaults" {
  description = "Named test cluster profile to deploy and default settings to be used for our aws clusters."
  type        = object({
    instance_architecture = string
    instance_type         = string
    instance_memory       = number
    instance_tags         = map(string)
  })
  default     = {
    instance_architecture = "amd64"
    instance_type         = "m6a.2xlarge"
    instance_memory       = 32
    instance_tags         = {
      Name = "dev"
    }
  }
}

variable "cockroach_disk_size_gb" {
  default = 200
}

variable "cockroach_disk_type" {
  default = "gp3"
}

variable "cockroach_disk_iops" {
  default = null
}

variable "cockroach_disk_throughput" {
  default = null
}


############################
# Distributed Connection Pooling
############################

variable "proxy_defaults" {
  description = "Default settings to be used for our aws instances that will be used to proxy requests."
  type        = object({
    instance_architecture = string
    instance_type         = string
  })
  default     = {
    instance_architecture = "amd64"
    instance_type         = "c6a.large"
  }
}

variable "ha_node_count" {
  type        = number
  description = "Number of high availaility nodes per enabled region."
  default     = 2
}

variable "pgb_port" {
  type = number
  default = 5432
}
variable "db_port"  {
  type = number
  default = 26257
}
variable "ui_port"  {
  type = number
  default = 8080
}

############################
# AMI / access
############################

variable "ssh_key_name" {
  type        = string
  description = "EC2 key pair name."
}

variable "vm_user" {
  type        = string
  default     = "debian"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key material."
}
