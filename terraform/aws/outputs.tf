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
