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
  inbound_cidrs = distinct(concat([var.vpc_cidr], var.allowed_inbound_cidrs))

  common_tags = merge(var.project_tags, {
    Name = var.name
  })

  # If var.private_subnet_cidrs is provided, use it.
  # Otherwise auto-generate one per AZ, using indices AFTER the public subnets
  # to avoid overlap: public uses 0..(N-1), private uses N..(2N-1)
  private_subnet_cidrs = length(var.private_subnet_cidrs) > 0 ? var.private_subnet_cidrs : [
    for idx, az in local.azs :
    cidrsubnet(var.vpc_cidr, var.public_subnet_newbits, idx + length(local.azs))
  ]

  private_subnets_by_az = {
    for idx, az in local.azs : az => local.private_subnet_cidrs[idx]
  }
}
