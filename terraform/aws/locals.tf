locals {
  dns_primary_region = var.enabled_regions[0]

  crdb_zone_id = (
    local.dns_primary_region == "us-east-1" ? aws_route53_zone.crdb_use1[0].zone_id :
    local.dns_primary_region == "us-east-2" ? aws_route53_zone.crdb_use2[0].zone_id :
    local.dns_primary_region == "us-west-1" ? aws_route53_zone.crdb_usw1[0].zone_id :
    aws_route53_zone.crdb_usw2[0].zone_id
  )

  tgw_id = (
    local.dns_primary_region == "us-east-1" ? aws_ec2_transit_gateway.hub_use1[0].id :
    local.dns_primary_region == "us-east-2" ? aws_ec2_transit_gateway.hub_use2[0].id :
    local.dns_primary_region == "us-west-1" ? aws_ec2_transit_gateway.hub_usw1[0].id :
    aws_ec2_transit_gateway.hub_usw2[0].id
  )

  region_config = {
    us-east-1 = {
      cidr     = var.vpc_cidrs["us-east-1"]
    }
    us-east-2 = {
      cidr     = var.vpc_cidrs["us-east-2"]
    }
    us-west-1 = {
      cidr     = var.vpc_cidrs["us-west-1"]
    }
    us-west-2 = {
      cidr     = var.vpc_cidrs["us-west-2"]
    }
  }

  enabled_region_configs = {
    for r in var.enabled_regions :
    r => local.region_config[r]
  }

  all_enabled_vpc_cidrs = [
    for r in var.enabled_regions :
    var.vpc_cidrs[r]
  ]


  # define cluster profiles for the system under test
  cluster_profiles = {
#    t3a-micro = {
#      instance_type = "t3a.micro"
#    }
    c6in-4xlarge = {
      instance_type = "c6in.4xlarge"
    }
    c6id-4xlarge = {
      instance_type = "c6id.4xlarge"
    }
    c6i-4xlarge = {
      instance_type = "c6i.4xlarge"
    }
    c5d-4xlarge = {
      instance_type = "c5d.4xlarge"
    }
    c5-4xlarge = {
      instance_type = "c5.4xlarge"
    }
    c7g-4xlarge = {
      instance_type = "c7g.4xlarge"
      instance_architecture = "arm64"
    }
    c6g-4xlarge = {
      instance_type = "c6g.4xlarge"
      instance_architecture = "arm64"
    }
    c6gn-4xlarge = {
      instance_type = "c6gn.4xlarge"
      instance_architecture = "arm64"
    }
    c6gd-4xlarge = {
      instance_type = "c6gd.4xlarge"
      instance_architecture = "arm64"
    }
    c6a-4xlarge = {
      instance_type = "c6a.4xlarge"
    }
    c5ad-4xlarge = {
      instance_type = "c5ad.4xlarge"
    }
    c5a-4xlarge = {
      instance_type = "c5a.4xlarge"
    }
    c7a-4xlarge = {
      instance_type = "c7a.4xlarge"
    }
    c7i-4xlarge = {
      instance_type = "c7i.4xlarge"
    }
    m6a-2xlarge = {
      instance_type = "m6a.2xlarge"
    }
    m6i-2xlarge = {
      instance_type = "m6i.2xlarge"
    }
    m5d-4xlarge = {
      instance_type = "m5d.4xlarge"
      instance_memory = 64
    }
    m5-4xlarge = {
      instance_type = "m5.4xlarge"
      instance_memory = 64
    }
    m4-4xlarge = {
      instance_type = "m4.4xlarge"
      instance_memory = 64
    }
    c6in-8xlarge = {
      instance_type = "c6in.8xlarge"
      instance_memory = 64
    }
    m5a-4xlarge = {
      instance_type = "m5a.4xlarge"
      instance_memory = 64
    }
    m5ad-4xlarge = {
      instance_type = "m5ad.4xlarge"
      instance_memory = 64
    }
    c6id-8xlarge = {
      instance_type = "c6id.8xlarge"
      instance_memory = 64
    }
    c6i-8xlarge = {
      instance_type = "c6i.8xlarge"
      instance_memory = 64
    }
    m6in-4xlarge = {
      instance_type = "m6in.4xlarge"
      instance_memory = 64
    }
    m6idn-4xlarge = {
      instance_type = "m6idn.4xlarge"
      instance_memory = 64
    }
    m6id-4xlarge = {
      instance_type = "m6id.4xlarge"
      instance_memory = 64
    }
    m6i-4xlarge = {
      instance_type = "m6i.4xlarge"
      instance_memory = 64
    }
    m5n-4xlarge = {
      instance_type = "m5n.4xlarge"
      instance_memory = 64
    }
    m5dn-4xlarge = {
      instance_type = "m5dn.4xlarge"
      instance_memory = 64
    }
    c5a-8xlarge = {
      instance_type = "c5a.8xlarge"
      instance_memory = 64
    }
    c5ad-8xlarge = {
      instance_type = "c5ad.8xlarge"
      instance_memory = 64
    }
    c7g-8xlarge = {
      instance_type = "c7g.8xlarge"
      instance_architecture = "arm64"
      instance_memory = 64
    }
    m6a-4xlarge = {
      instance_type = "m6a.4xlarge"
      instance_memory = 64
    }
    m7g-4xlarge = {
      instance_type = "m7g.4xlarge"
      instance_architecture = "arm64"
      instance_memory = 64
    }
    c6a-8xlarge = {
      instance_type = "c6a.8xlarge"
      instance_memory = 64
    }
    c7a-8xlarge = {
      instance_type = "c7a.8xlarge"
      instance_memory = 64
    }
    c7i-8xlarge = {
      instance_type = "c7i.8xlarge"
      instance_memory = 64
    }
    m7a-4xlarge = {
      instance_type = "m7a.4xlarge"
      instance_memory = 64
    }
    m7i-4xlarge = {
      instance_type = "m7i.4xlarge"
      instance_memory = 64
    }
    m7i-flex-4xlarge = {
      instance_type = "m7i-flex.4xlarge"
      instance_memory = 64
    }
    c6g-8xlarge = {
      instance_type = "c6g.8xlarge"
      instance_architecture = "arm64"
      instance_memory = 64
    }
    m6gd-4xlarge = {
      instance_type = "m6gd.4xlarge"
      instance_architecture = "arm64"
      instance_memory = 64
    }
    m6g-4xlarge = {
      instance_type = "m6g.4xlarge"
      instance_architecture = "arm64"
      instance_memory = 64
    }
    c6gn-8xlarge = {
      instance_type = "c6gn.8xlarge"
      instance_architecture = "arm64"
      instance_memory = 64
    }
    c6gd-8xlarge = {
      instance_type = "c6gd.8xlarge"
      instance_architecture = "arm64"
      instance_memory = 64
    }
    m5d-8xlarge = {
      instance_type = "m5d.8xlarge"
      instance_memory = 128
    }
    m5-8xlarge = {
      instance_type = "m5.8xlarge"
      instance_memory = 128
    }
    r5d-4xlarge = {
      instance_type = "r5d.4xlarge"
      instance_memory = 128
    }
    r5-4xlarge = {
      instance_type = "r5.4xlarge"
      instance_memory = 128
    }
    m6in-8xlarge = {
      instance_type = "m6in.8xlarge"
      instance_memory = 128
    }
    m6idn-8xlarge = {
      instance_type = "m6idn.8xlarge"
      instance_memory = 128
    }
    r5a-4xlarge = {
      instance_type = "r5a.4xlarge"
      instance_memory = 128
    }
    r5ad-4xlarge = {
      instance_type = "r5ad.4xlarge"
      instance_memory = 128
    }
    m5a-8xlarge = {
      instance_type = "m5a.8xlarge"
      instance_memory = 128
    }
    m5ad-8xlarge = {
      instance_type = "m5ad.8xlarge"
      instance_memory = 128
    }
    m6id-8xlarge = {
      instance_type = "m6id.8xlarge"
      instance_memory = 128
    }
    m6i-8xlarge = {
      instance_type = "m6i.8xlarge"
      instance_memory = 128
    }
    r6in-4xlarge = {
      instance_type = "r6in.4xlarge"
      instance_memory = 128
    }
    r6idn-4xlarge = {
      instance_type = "r6idn.4xlarge"
      instance_memory = 128
    }
    r6id-4xlarge = {
      instance_type = "r6id.4xlarge"
      instance_memory = 128
    }
    r6i-4xlarge = {
      instance_type = "r6i.4xlarge"
      instance_memory = 128
    }
    m5n-8xlarge = {
      instance_type = "m5n.8xlarge"
      instance_memory = 128
    }
    m5dn-8xlarge = {
      instance_type = "m5dn.8xlarge"
      instance_memory = 128
    }
    r6a-4xlarge = {
      instance_type = "r6a.4xlarge"
      instance_memory = 128
    }
    r5n-4xlarge = {
      instance_type = "r5n.4xlarge"
      instance_memory = 128
    }
    m6a-8xlarge = {
      instance_type = "m6a.8xlarge"
      instance_memory = 128
    }
    r5dn-4xlarge = {
      instance_type = "r5dn.4xlarge"
      instance_memory = 128
    }
    r5b-4xlarge = {
      instance_type = "r5b.4xlarge"
      instance_memory = 128
    }
    m7a-8xlarge = {
      instance_type = "m7a.8xlarge"
      instance_memory = 128
    }
    m7i-8xlarge = {
      instance_type = "m7i.8xlarge"
      instance_memory = 128
    } 
    m7i-flex-8xlarge = {
      instance_type = "m7i-flex.8xlarge"
      instance_memory = 128
    }
    r7a-4xlarge = {
      instance_type = "r7a.4xlarge"
      instance_memory = 128
    }  
    r7i-4xlarge = {
      instance_type = "r7i.4xlarge"
      instance_memory = 128
    }
    r7iz-4xlarge = {
      instance_type = "r7iz.4xlarge"
      instance_memory = 128
    }
    m7g-8xlarge = {
      instance_type = "m7g.8xlarge"
      instance_architecture = "arm64"
      instance_memory = 128
    }
    r6g-4xlarge = {
      instance_type = "r6g.4xlarge"
      instance_architecture = "arm64"
      instance_memory = 128
    }
    r6gd-4xlarge = {
      instance_type = "r6gd.4xlarge"
      instance_architecture = "arm64"
      instance_memory = 128
    }
    r7g-4xlarge = {
      instance_type = "r7g.4xlarge"
      instance_architecture = "arm64"
      instance_memory = 128
    }
    m6gd-8xlarge = {
      instance_type = "m6gd.8xlarge"
      instance_architecture = "arm64"
      instance_memory = 128
    }
    m6g-8xlarge = {
      instance_type = "m6g.8xlarge"
      instance_architecture = "arm64"
      instance_memory = 128
    }
    r5d-8xlarge = {
      instance_type = "r5d.8xlarge"
      instance_memory = 256
    }
    r5-8xlarge = {
      instance_type = "r5.8xlarge"
      instance_memory = 256
    }
    r6in-8xlarge = {
      instance_type = "r6in.8xlarge"
      instance_memory = 256
    }
    r6idn-8xlarge = {
      instance_type = "r6idn.8xlarge"
      instance_memory = 256
    }
    r6id-8xlarge = {
      instance_type = "r6id.8xlarge"
      instance_memory = 256
    }
    r6i-8xlarge = {
      instance_type = "r6i.8xlarge"
      instance_memory = 256
    }
    r5n-8xlarge = {
      instance_type = "r5n.8xlarge"
      instance_memory = 256
    }
    r5dn-8xlarge = {
      instance_type = "r5dn.8xlarge"
      instance_memory = 256
    }
    r5b-8xlarge = {
      instance_type = "r5b.8xlarge"
      instance_memory = 256
    }
    r7g-8xlarge = {
      instance_type = "r7g.8xlarge"
      instance_architecture = "arm64"
      instance_memory = 256
    }
    r5a-8xlarge = {
      instance_type = "r5a.8xlarge"
      instance_memory = 256
    }
    r5ad-8xlarge = {
      instance_type = "r5ad.8xlarge"
      instance_memory = 256
    }
    r6gd-8xlarge = {
      instance_type = "r6gd.8xlarge"
      instance_architecture = "arm64"
      instance_memory = 256
    }
    r6g-8xlarge = {
      instance_type = "r6g.8xlarge"
      instance_architecture = "arm64"
      instance_memory = 256
    }
    r6a-8xlarge = {
      instance_type = "r6a.8xlarge"
      instance_memory = 256
    }
    r7a-8xlarge = {
      instance_type = "r7a.8xlarge"
      instance_memory = 256
    }
    r7i-8xlarge = {
      instance_type = "r7i.8xlarge"
      instance_memory = 256
    }
    r7iz-8xlarge = {
      instance_type = "r7iz.8xlarge"
      instance_memory = 256
    }
  }

  # merge cluster default settings with the specific cluster settings defined above
  selected_cluster = merge(
    var.cluster_defaults,
    local.cluster_profiles[var.cluster_profile_name]
  )

  all_node_records = flatten([
    for r in var.enabled_regions :
    local.cockroach_by_region[r].node_records
  ])

  all_dcp_records = flatten([
    for r in var.enabled_regions :
    local.dcp_by_region[r].dcp_records
  ])

  vpc_route_tables = merge(
    contains(var.enabled_regions, "us-east-1") ? {
      us-east-1 = module.vpc_us_east_1[0].public_route_table_id
    } : {},
    contains(var.enabled_regions, "us-east-2") ? {
      us-east-2 = module.vpc_us_east_2[0].public_route_table_id
    } : {},
    contains(var.enabled_regions, "us-west-1") ? {
      us-west-1 = module.vpc_us_west_1[0].public_route_table_id
    } : {},
    contains(var.enabled_regions, "us-west-2") ? {
      us-west-2 = module.vpc_us_west_2[0].public_route_table_id
    } : {}
  )

  vpc_by_region = merge(
    contains(var.enabled_regions, "us-east-1") ? {
      us-east-1 = module.vpc_us_east_1[0]
    } : {},
    contains(var.enabled_regions, "us-east-2") ? {
      us-east-2 = module.vpc_us_east_2[0]
    } : {},
    contains(var.enabled_regions, "us-west-1") ? {
      us-west-1 = module.vpc_us_west_1[0]
    } : {},
    contains(var.enabled_regions, "us-west-2") ? {
      us-west-2 = module.vpc_us_west_2[0]
    } : {}
  )

  cockroach_by_region = merge(
    contains(var.enabled_regions, "us-east-1") ? {
      us-east-1 = module.cockroach_us_east_1[0]
    } : {},
    contains(var.enabled_regions, "us-east-2") ? {
      us-east-2 = module.cockroach_us_east_2[0]
    } : {},
    contains(var.enabled_regions, "us-west-1") ? {
      us-west-1 = module.cockroach_us_west_1[0]
    } : {},
    contains(var.enabled_regions, "us-west-2") ? {
      us-west-2 = module.cockroach_us_west_2[0]
    } : {}
  )

  dcp_by_region = merge(
    contains(var.enabled_regions, "us-east-1") ? {
      us-east-1 = module.dcp_us_east_1[0]
    } : {},
    contains(var.enabled_regions, "us-east-2") ? {
      us-east-2 = module.dcp_us_east_2[0]
    } : {},
    contains(var.enabled_regions, "us-west-1") ? {
      us-west-1 = module.dcp_us_west_1[0]
    } : {},
    contains(var.enabled_regions, "us-west-2") ? {
      us-west-2 = module.dcp_us_west_2[0]
    } : {}
  )
}
