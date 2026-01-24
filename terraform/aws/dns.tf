resource "aws_route53_zone" "crdb_use1" {
  count    = local.dns_primary_region == "us-east-1" ? 1 : 0
  provider = aws.use1

  name = var.dns_zone

  vpc {
    vpc_id = module.vpc_us_east_1[0].vpc_id
  }

  tags = var.project_tags
}

resource "aws_route53_zone" "crdb_use2" {
  count    = local.dns_primary_region == "us-east-2" ? 1 : 0
  provider = aws.use2

  name = var.dns_zone

  vpc {
    vpc_id = module.vpc_us_east_2[0].vpc_id
  }

  tags = var.project_tags
}

resource "aws_route53_zone" "crdb_usw1" {
  count    = local.dns_primary_region == "us-west-1" ? 1 : 0
  provider = aws.usw1

  name = var.dns_zone

  vpc {
    vpc_id = module.vpc_us_west_1[0].vpc_id
  }

  tags = var.project_tags
}

resource "aws_route53_zone" "crdb_usw2" {
  count    = local.dns_primary_region == "us-west-2" ? 1 : 0
  provider = aws.usw2

  name = var.dns_zone

  vpc {
    vpc_id = module.vpc_us_west_2[0].vpc_id
  }

  tags = var.project_tags
}

resource "aws_route53_zone_association" "use1" {
  count    = contains(var.enabled_regions, "us-east-1") && local.dns_primary_region != "us-east-1" ? 1 : 0
  provider = aws.use1

  zone_id = local.crdb_zone_id
  vpc_id  = module.vpc_us_east_1[0].vpc_id
}

resource "aws_route53_zone_association" "use2" {
  count    = contains(var.enabled_regions, "us-east-2") && local.dns_primary_region != "us-east-2" ? 1 : 0
  provider = aws.use2

  zone_id = local.crdb_zone_id
  vpc_id  = module.vpc_us_east_2[0].vpc_id
}

resource "aws_route53_zone_association" "usw1" {
  count    = contains(var.enabled_regions, "us-west-1") && local.dns_primary_region != "us-west-1" ? 1 : 0
  provider = aws.usw1

  zone_id = local.crdb_zone_id
  vpc_id  = module.vpc_us_west_1[0].vpc_id
}

resource "aws_route53_zone_association" "usw2" {
  count    = contains(var.enabled_regions, "us-west-2") && local.dns_primary_region != "us-west-2" ? 1 : 0
  provider = aws.usw2

  zone_id = local.crdb_zone_id
  vpc_id  = module.vpc_us_west_2[0].vpc_id
}

resource "aws_route53_record" "crdb_nodes" {
  for_each = {
    for rec in local.all_node_records :
    rec.name => rec
  }

  zone_id = local.crdb_zone_id
  name    = each.key
  type    = "A"
  ttl     = 30
  records = [each.value.private_ip]
}

resource "aws_route53_record" "crdb_endpoints" {
  for_each = local.dcp_by_region

  zone_id = local.crdb_zone_id
  name    = "db.${each.key}.${var.dns_zone}"
  type    = "A"
  ttl     = 30

  records = [each.value.vip_private_ip]
}

resource "aws_route53_record" "pgb_endpoints" {
  for_each = local.dcp_by_region

  zone_id = local.crdb_zone_id
  name    = "pgb.${each.key}.${var.dns_zone}"
  type    = "A"
  ttl     = 30

  records = [each.value.vip_private_ip]
}

resource "aws_route53_record" "public_db_endpoints" {
  for_each = var.public_zone_id != "" ? local.dcp_by_region : {}

  zone_id = var.public_zone_id
  name    = "db.${each.key}.${var.dns_zone}"
  type    = "A"
  ttl     = 30
  records = [each.value.eip_public_ip]
}

resource "aws_route53_record" "public_pgb_endpoints" {
  for_each = var.public_zone_id != "" ? local.dcp_by_region : {}

  zone_id = var.public_zone_id
  name    = "pgb.${each.key}.${var.dns_zone}"
  type    = "A"
  ttl     = 30
  records = [each.value.eip_public_ip]
}
