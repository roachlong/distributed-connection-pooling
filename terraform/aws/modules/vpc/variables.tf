variable "name" {
  type        = string
  description = "Name prefix for all VPC resources (per-region)."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC."
  default     = "10.0.0.0/16"
}

variable "az_count" {
  type        = number
  description = "How many AZs to use in the current region."
  default     = 3

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 6
    error_message = "az_count must be between 1 and 6."
  }
}

variable "public_subnet_newbits" {
  type        = number
  description = "Newbits for cidrsubnet() when carving public subnets from vpc_cidr. 8 => /24s from a /16."
  default     = 8

  validation {
    condition     = var.public_subnet_newbits >= 1 && var.public_subnet_newbits <= 12
    error_message = "public_subnet_newbits must be between 1 and 12."
  }
}

# you can either provide explicit private subnet CIDRs, or leave empty
# and script will auto-create one private subnet per AZ using cidrsubnet().
variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Optional explicit CIDR blocks for private subnets (one per AZ). If empty, auto-generate."
  default     = []
}

variable "ssh_ip_range" {
  type        = string
  description = "CIDR allowed to SSH into instances (e.g. your public IP/32)."
  default     = "0.0.0.0/0"

  validation {
    condition     = length(split("/", var.ssh_ip_range)) == 2
    error_message = "You must supply a CIDR range with a '/', e.g. 203.0.113.10/32."
  }
}

variable "allowed_inbound_cidrs" {
  type        = list(string)
  description = "Additional CIDRs allowed to reach Cockroach ports (26257/8080) when using the shared SG. Add other regional VPC CIDRs here at the top level."
  default     = []
}

variable "create_node_security_group" {
  type        = bool
  description = "Whether to create a reusable node SG (SSH + CRDB ports)."
  default     = true
}

variable "create_proxy_security_group" {
  type        = bool
  description = "Whether to create a reusable proxy SG (SSH + DCP ports)."
  default     = true
}

variable "project_tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}

variable "pgb_port" {
  type    = number
  default = 5432
}

variable "db_port" {
  type    = number
  default = 26257
}

variable "ui_port" {
  type    = number
  default = 8080
}
