resource "aws_ec2_transit_gateway" "hub_use1" {
  count    = local.dns_primary_region == "us-east-1" ? 1 : 0
  provider = aws.use1

  description = "TGW hub us-east-1"

  tags = merge(var.project_tags, {
    Region = "us-east-1"
    Role   = "tgw-hub"
  })
}

resource "aws_ec2_transit_gateway" "hub_use2" {
  count    = local.dns_primary_region == "us-east-2" ? 1 : 0
  provider = aws.use2

  description = "TGW hub us-east-2"

  tags = merge(var.project_tags, {
    Region = "us-east-2"
    Role   = "tgw-hub"
  })
}

resource "aws_ec2_transit_gateway" "hub_usw1" {
  count    = local.dns_primary_region == "us-west-1" ? 1 : 0
  provider = aws.usw1

  description = "TGW hub us-west-1"

  tags = merge(var.project_tags, {
    Region = "us-west-1"
    Role   = "tgw-hub"
  })
}

resource "aws_ec2_transit_gateway" "hub_usw2" {
  count    = local.dns_primary_region == "us-west-2" ? 1 : 0
  provider = aws.usw2

  description = "TGW hub us-west-2"

  tags = merge(var.project_tags, {
    Region = "us-west-2"
    Role   = "tgw-hub"
  })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "use1" {
  count    = contains(var.enabled_regions, "us-east-1") ? 1 : 0
  provider = aws.use1

  transit_gateway_id = local.tgw_id
  vpc_id             = module.vpc_us_east_1[0].vpc_id
  subnet_ids         = module.vpc_us_east_1[0].public_subnet_ids

  tags = merge(var.project_tags, {
    Region = "us-east-1"
  })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "use2" {
  count    = contains(var.enabled_regions, "us-east-2") ? 1 : 0
  provider = aws.use2

  transit_gateway_id = local.tgw_id
  vpc_id             = module.vpc_us_east_2[0].vpc_id
  subnet_ids         = module.vpc_us_east_2[0].public_subnet_ids

  tags = merge(var.project_tags, {
    Region = "us-east-2"
  })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "usw1" {
  count    = contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider = aws.usw1

  transit_gateway_id = local.tgw_id
  vpc_id             = module.vpc_us_west_1[0].vpc_id
  subnet_ids         = module.vpc_us_west_1[0].public_subnet_ids

  tags = merge(var.project_tags, {
    Region = "us-west-1"
  })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "usw2" {
  count    = contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.usw2

  transit_gateway_id = local.tgw_id
  vpc_id             = module.vpc_us_west_2[0].vpc_id
  subnet_ids         = module.vpc_us_west_2[0].public_subnet_ids

  tags = merge(var.project_tags, {
    Region = "us-west-2"
  })
}

resource "aws_route" "use1_to_remote" {
  for_each = {
    for r in var.enabled_regions :
    r => r
    if r != "us-east-1" && contains(var.enabled_regions, "us-east-1")
  }

  provider = aws.use1

  route_table_id         = local.vpc_route_tables[each.value]
  destination_cidr_block = var.vpc_cidrs[each.key]
  transit_gateway_id     = local.tgw_id
}

resource "aws_route" "use2_to_remote" {
  for_each = {
    for r in var.enabled_regions :
    r => r
    if r != "us-east-2" && contains(var.enabled_regions, "us-east-2")
  }

  provider = aws.use2

  route_table_id         = local.vpc_route_tables[each.value]
  destination_cidr_block = var.vpc_cidrs[each.key]
  transit_gateway_id     = local.tgw_id
}

resource "aws_route" "usw1_to_remote" {
  for_each = {
    for r in var.enabled_regions :
    r => r
    if r != "us-west-1" && contains(var.enabled_regions, "us-west-1")
  }

  provider = aws.usw1

  route_table_id         = local.vpc_route_tables[each.value]
  destination_cidr_block = var.vpc_cidrs[each.key]
  transit_gateway_id     = local.tgw_id
}

resource "aws_route" "usw2_to_remote" {
  for_each = {
    for r in var.enabled_regions :
    r => r
    if r != "us-west-2" && contains(var.enabled_regions, "us-west-2")
  }

  provider = aws.usw2

  route_table_id         = local.vpc_route_tables[each.value]
  destination_cidr_block = var.vpc_cidrs[each.key]
  transit_gateway_id     = local.tgw_id
}
