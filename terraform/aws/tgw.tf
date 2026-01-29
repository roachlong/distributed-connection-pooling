# 1 Transit Gateways, one per enabled region, using the region provider

resource "aws_ec2_transit_gateway" "hub_use1" {
  count    = contains(var.enabled_regions, "us-east-1") ? 1 : 0
  provider = aws.use1

  description = "TGW hub us-east-1"

  tags = {
    Name    = "${var.project_name}-tgw-us-east-1"
    Region  = "us-east-1"
    Project = var.project_name
  }
}

resource "aws_ec2_transit_gateway" "hub_use2" {
  count    = contains(var.enabled_regions, "us-east-2") ? 1 : 0
  provider = aws.use2

  description = "TGW hub us-east-2"

  tags = {
    Name    = "${var.project_name}-tgw-us-east-2"
    Region  = "us-east-2"
    Project = var.project_name
  }
}

resource "aws_ec2_transit_gateway" "hub_usw1" {
  count    = contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider = aws.usw1

  description = "TGW hub us-west-1"

  tags = {
    Name    = "${var.project_name}-tgw-us-west-1"
    Region  = "us-west-1"
    Project = var.project_name
  }
}

resource "aws_ec2_transit_gateway" "hub_usw2" {
  count    = contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.usw2

  description = "TGW hub us-west-2"

  tags = {
    Name    = "${var.project_name}-tgw-us-west-2"
    Region  = "us-west-2"
    Project = var.project_name
  }
}




# 2 Transit Gateway VPC Attachments, attach each region’s VPC to its local TGW

resource "aws_ec2_transit_gateway_vpc_attachment" "use1" {
  count    = contains(var.enabled_regions, "us-east-1") ? 1 : 0
  provider = aws.use1

  transit_gateway_id = aws_ec2_transit_gateway.hub_use1[0].id
  vpc_id             = module.vpc_us_east_1[0].vpc_id
  subnet_ids         = module.vpc_us_east_1[0].private_subnet_ids

  tags = {
    Name = "${var.project_name}-tgw-attach-us-east-1"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "use2" {
  count    = contains(var.enabled_regions, "us-east-2") ? 1 : 0
  provider = aws.use2

  transit_gateway_id = aws_ec2_transit_gateway.hub_use2[0].id
  vpc_id             = module.vpc_us_east_2[0].vpc_id
  subnet_ids         = module.vpc_us_east_2[0].private_subnet_ids

  tags = {
    Name = "${var.project_name}-tgw-attach-us-east-2"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "usw1" {
  count    = contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider = aws.usw1

  transit_gateway_id = aws_ec2_transit_gateway.hub_usw1[0].id
  vpc_id             = module.vpc_us_west_1[0].vpc_id
  subnet_ids         = module.vpc_us_west_1[0].private_subnet_ids

  tags = {
    Name = "${var.project_name}-tgw-attach-us-west-1"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "usw2" {
  count    = contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.usw2

  transit_gateway_id = aws_ec2_transit_gateway.hub_usw2[0].id
  vpc_id             = module.vpc_us_west_2[0].vpc_id
  subnet_ids         = module.vpc_us_west_2[0].private_subnet_ids

  tags = {
    Name = "${var.project_name}-tgw-attach-us-west-2"
  }
}




# 3 Transit Gateway Peering Attachments, one requester and one accepter for each unique regional pair

resource "aws_ec2_transit_gateway_peering_attachment" "use1_use2" {
  count    = contains(var.enabled_regions, "us-east-1") && contains(var.enabled_regions, "us-east-2") ? 1 : 0
  provider = aws.use1

  transit_gateway_id      = aws_ec2_transit_gateway.hub_use1[0].id
  peer_transit_gateway_id = aws_ec2_transit_gateway.hub_use2[0].id
  peer_region             = "us-east-2"

  tags = {
    Name = "tgw-peer-use1-use2"
  }
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "use2_use1" {
  count    = contains(var.enabled_regions, "us-east-1") && contains(var.enabled_regions, "us-east-2") ? 1 : 0
  provider = aws.use2
  
  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.use1_use2[0].id
}

resource "aws_ec2_transit_gateway_peering_attachment" "use1_usw1" {
  count    = contains(var.enabled_regions, "us-east-1") && contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider = aws.use1

  transit_gateway_id      = aws_ec2_transit_gateway.hub_use1[0].id
  peer_transit_gateway_id = aws_ec2_transit_gateway.hub_usw1[0].id
  peer_region             = "us-west-1"

  tags = {
    Name = "tgw-peer-use1-usw1"
  }
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "usw1_use1" {
  count    = contains(var.enabled_regions, "us-east-1") && contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider = aws.usw1
  
  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.use1_usw1[0].id
}

resource "aws_ec2_transit_gateway_peering_attachment" "use1_usw2" {
  count    = contains(var.enabled_regions, "us-east-1") && contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.use1

  transit_gateway_id      = aws_ec2_transit_gateway.hub_use1[0].id
  peer_transit_gateway_id = aws_ec2_transit_gateway.hub_usw2[0].id
  peer_region             = "us-west-2"

  tags = {
    Name = "tgw-peer-use1-usw2"
  }
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "usw2_use1" {
  count    = contains(var.enabled_regions, "us-east-1") && contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.usw2
  
  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.use1_usw2[0].id
}

resource "aws_ec2_transit_gateway_peering_attachment" "use2_usw1" {
  count    = contains(var.enabled_regions, "us-east-2") && contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider = aws.use2

  transit_gateway_id      = aws_ec2_transit_gateway.hub_use2[0].id
  peer_transit_gateway_id = aws_ec2_transit_gateway.hub_usw1[0].id
  peer_region             = "us-west-1"

  tags = {
    Name = "tgw-peer-use2-usw1"
  }
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "usw1_use2" {
  count    = contains(var.enabled_regions, "us-east-2") && contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider = aws.usw1
  
  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.use2_usw1[0].id
}

resource "aws_ec2_transit_gateway_peering_attachment" "use2_usw2" {
  count    = contains(var.enabled_regions, "us-east-2") && contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.use2

  transit_gateway_id      = aws_ec2_transit_gateway.hub_use2[0].id
  peer_transit_gateway_id = aws_ec2_transit_gateway.hub_usw2[0].id
  peer_region             = "us-west-2"

  tags = {
    Name = "tgw-peer-use2-usw2"
  }
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "usw2_use2" {
  count    = contains(var.enabled_regions, "us-east-2") && contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.usw2
  
  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.use2_usw2[0].id
}

resource "aws_ec2_transit_gateway_peering_attachment" "usw1_usw2" {
  count    = contains(var.enabled_regions, "us-west-1") && contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.usw1

  transit_gateway_id      = aws_ec2_transit_gateway.hub_usw1[0].id
  peer_transit_gateway_id = aws_ec2_transit_gateway.hub_usw2[0].id
  peer_region             = "us-west-2"

  tags = {
    Name = "tgw-peer-usw1-usw2"
  }
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "usw2_usw1" {
  count    = contains(var.enabled_regions, "us-west-1") && contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.usw2
  
  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.usw1_usw2[0].id
}



# 4 AWS Routes, one per region to all other VPC CIDRs

resource "aws_route" "use1_to_remote" {
  for_each = contains(var.enabled_regions, "us-east-1") ? {
    for r, cidr in var.vpc_cidrs : r => cidr
    if r != "us-east-1" && contains(var.enabled_regions, r)
  } : {}

  provider               = aws.use1
  route_table_id         = module.vpc_us_east_1[0].public_route_table_id
  destination_cidr_block = each.value
  transit_gateway_id     = aws_ec2_transit_gateway.hub_use1[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.use1]
}

resource "aws_route" "use2_to_remote" {
  for_each = contains(var.enabled_regions, "us-east-2") ? {
    for r, cidr in var.vpc_cidrs : r => cidr
    if r != "us-east-2" && contains(var.enabled_regions, r)
  } : {}

  provider               = aws.use2
  route_table_id         = module.vpc_us_east_2[0].public_route_table_id
  destination_cidr_block = each.value
  transit_gateway_id     = aws_ec2_transit_gateway.hub_use2[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.use2]
}

resource "aws_route" "usw1_to_remote" {
  for_each = contains(var.enabled_regions, "us-west-1") ? {
    for r, cidr in var.vpc_cidrs : r => cidr
    if r != "us-west-1" && contains(var.enabled_regions, r)
  } : {}

  provider               = aws.usw1
  route_table_id         = module.vpc_us_west_1[0].public_route_table_id
  destination_cidr_block = each.value
  transit_gateway_id     = aws_ec2_transit_gateway.hub_usw1[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.usw1]
}

resource "aws_route" "usw2_to_remote" {
  for_each = contains(var.enabled_regions, "us-west-2") ? {
    for r, cidr in var.vpc_cidrs : r => cidr
    if r != "us-west-2" && contains(var.enabled_regions, r)
  } : {}

  provider               = aws.usw2
  route_table_id         = module.vpc_us_west_2[0].public_route_table_id
  destination_cidr_block = each.value
  transit_gateway_id     = aws_ec2_transit_gateway.hub_usw2[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.usw2]
}




# 5 Transit Gateway Routes, one for each remote CIDR → peering attachment

resource "aws_ec2_transit_gateway_route" "use1_to_use2_vpc" {
  count    = contains(var.enabled_regions, "us-east-1") && contains(var.enabled_regions, "us-east-2") ? 1 : 0
  provider = aws.use1

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_use1[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-east-2"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.use1_use2[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.use2_use1
  ]
}

resource "aws_ec2_transit_gateway_route" "use1_to_usw1_vpc" {
  count    = contains(var.enabled_regions, "us-east-1") && contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider = aws.use1

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_use1[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-west-1"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.use1_usw1[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.usw1_use1
  ]
}

resource "aws_ec2_transit_gateway_route" "use1_to_usw2_vpc" {
  count    = contains(var.enabled_regions, "us-east-1") && contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.use1

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_use1[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-west-2"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.use1_usw2[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.usw2_use1
  ]
}

resource "aws_ec2_transit_gateway_route" "use2_to_use1_vpc" {
  count    = contains(var.enabled_regions, "us-east-2") && contains(var.enabled_regions, "us-east-1") ? 1 : 0
  provider = aws.use2

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_use2[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-east-1"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.use1_use2[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.use2_use1
  ]
}

resource "aws_ec2_transit_gateway_route" "use2_to_usw1_vpc" {
  count    = contains(var.enabled_regions, "us-east-2") && contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider = aws.use2

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_use2[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-west-1"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.use2_usw1[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.usw1_use2
  ]
}

resource "aws_ec2_transit_gateway_route" "use2_to_usw2_vpc" {
  count    = contains(var.enabled_regions, "us-east-2") && contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.use2

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_use2[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-west-2"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.use2_usw2[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.usw2_use2
  ]
}

resource "aws_ec2_transit_gateway_route" "usw1_to_use1_vpc" {
  count    = contains(var.enabled_regions, "us-west-1") && contains(var.enabled_regions, "us-east-1") ? 1 : 0
  provider = aws.usw1

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_usw1[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-east-1"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.use1_usw1[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.usw1_use1
  ]
}

resource "aws_ec2_transit_gateway_route" "usw1_to_use2_vpc" {
  count    = contains(var.enabled_regions, "us-west-1") && contains(var.enabled_regions, "us-east-2") ? 1 : 0
  provider = aws.usw1

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_usw1[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-east-2"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.use2_usw1[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.usw1_use2
  ]
}

resource "aws_ec2_transit_gateway_route" "usw1_to_usw2_vpc" {
  count    = contains(var.enabled_regions, "us-west-1") && contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider = aws.usw1

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_usw1[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-west-2"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.usw1_usw2[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.usw2_usw1
  ]
}

resource "aws_ec2_transit_gateway_route" "usw2_to_use1_vpc" {
  count    = contains(var.enabled_regions, "us-west-2") && contains(var.enabled_regions, "us-east-1") ? 1 : 0
  provider = aws.usw2

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_usw2[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-east-1"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.use1_usw2[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.usw2_use1
  ]
}

resource "aws_ec2_transit_gateway_route" "usw2_to_use2_vpc" {
  count    = contains(var.enabled_regions, "us-west-2") && contains(var.enabled_regions, "us-east-2") ? 1 : 0
  provider = aws.usw2

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_usw2[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-east-2"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.use2_usw2[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.usw2_use2
  ]
}

resource "aws_ec2_transit_gateway_route" "usw2_to_usw1_vpc" {
  count    = contains(var.enabled_regions, "us-west-2") && contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider = aws.usw2

  transit_gateway_route_table_id = aws_ec2_transit_gateway.hub_usw2[0].association_default_route_table_id
  destination_cidr_block         = var.vpc_cidrs["us-west-1"]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.usw1_usw2[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.usw2_usw1
  ]
}
