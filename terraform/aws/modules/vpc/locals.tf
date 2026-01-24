locals {
  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(
      var.az_count,
      length(data.aws_availability_zones.available.names)
    )
  )

  # Always allow intra-VPC traffic for node-to-node comms.
  # Optionally include additional CIDRs (e.g., other regional VPC CIDRs) at the top level later.
  inbound_cidrs = distinct(concat([var.vpc_cidr], var.allowed_inbound_cidrs))

  common_tags = merge(var.project_tags, {
    Name = var.name
  })
}
