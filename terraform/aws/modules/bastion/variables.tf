variable "name" {
  type        = string
  description = "Name prefix for bastion resources"
}

variable "region" {
  type        = string
  description = "AWS region"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where bastion will be deployed"
}

variable "public_subnet_id" {
  type        = string
  description = "Public subnet ID for bastion instance"
}

variable "ssh_key_name" {
  type        = string
  description = "EC2 SSH key pair name"
}

variable "ssh_ip_range" {
  type        = string
  description = "CIDR range allowed to SSH to bastion"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for bastion"
  default     = "t3.micro"
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources"
  default     = {}
}

variable "vm_user" {
  type        = string
  description = "Username for SSH access"
  default     = "debian"
}

variable "ssh_key" {
  type        = string
  description = "SSH public key to add to authorized_keys"
}
