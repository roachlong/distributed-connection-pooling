output "cockroach_nodes" {
  value = {
    for r in var.enabled_regions : r => local.cockroach_by_region[r].node_records
  }
}

output "dcp_endpoints" {
  value = {
    for r in var.enabled_regions : r => local.dcp_by_region[r].dcp_records
  }
}

output "vpcs" {
  value = {
    for r in var.enabled_regions : r => {
      vpc_id = local.vpc_by_region[r].vpc_id
      cidr   = var.vpc_cidrs[r]
    }
  }
}

# Outputs for init-cockroach-cluster.sh automation script
output "bastion_public_ips" {
  description = "Public IPs of bastion hosts (for SSH access)"
  value = merge(
    contains(var.enabled_regions, "us-east-1") ? {
      "us-east-1" = module.bastion_us_east_1[0].bastion_public_ip
    } : {},
    contains(var.enabled_regions, "us-east-2") ? {
      "us-east-2" = module.bastion_us_east_2[0].bastion_public_ip
    } : {},
    contains(var.enabled_regions, "us-west-1") ? {
      "us-west-1" = module.bastion_us_west_1[0].bastion_public_ip
    } : {},
    contains(var.enabled_regions, "us-west-2") ? {
      "us-west-2" = module.bastion_us_west_2[0].bastion_public_ip
    } : {}
  )
}

output "crdb_private_ips" {
  description = "Private IPs of CockroachDB nodes (for cluster initialization)"
  value = {
    for r in var.enabled_regions : r => local.cockroach_by_region[r].private_ips
  }
}

output "vm_user" {
  description = "SSH user for EC2 instances"
  value       = var.vm_user
}

output "ssh_key_path" {
  description = "Path to SSH private key (if using default location)"
  value       = "~/.ssh/${var.ssh_key_name}.pem"
}

output "cockroach_organization" {
  description = "CockroachDB organization name (for license activation)"
  value       = var.cockroach_organization
}

output "cockroach_license" {
  description = "CockroachDB Enterprise license key"
  value       = var.cockroach_license
  sensitive   = true
}
