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

variable "s3_bucket_arns" {
  type        = list(string)
  description = "S3 bucket ARNs for IMPORT, BACKUP, and audit logs"
  default     = []
}

variable "permissions_boundary_arn" {
  type        = string
  description = "IAM permissions boundary ARN"
  default     = ""
}

variable "kms_key_id" {
  type        = string
  description = "KMS key ID for EBS volume encryption"
  default     = ""
}

variable "existing_iam_instance_profile_name" {
  type        = string
  description = "Name of existing IAM instance profile to use instead of creating new one (e.g., roachprod-testing)"
  default     = ""
}
