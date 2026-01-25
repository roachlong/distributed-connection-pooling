module "vpc_us_east_1" {
  count = contains(var.enabled_regions, "us-east-1") ? 1 : 0
  source = "./modules/vpc"
  providers = { aws = aws.use1 }
  name      = "${var.project_name}-us-east-1"
  vpc_cidr = var.vpc_cidrs["us-east-1"]
  az_count = var.az_count
  ssh_ip_range          = var.ssh_ip_range
  allowed_inbound_cidrs = local.all_enabled_vpc_cidrs
  pgb_port = var.pgb_port
  db_port = var.db_port
  ui_port = var.ui_port
  project_tags = merge(var.project_tags, { Region = "us-east-1" })
}

module "vpc_us_east_2" {
  count = contains(var.enabled_regions, "us-east-2") ? 1 : 0
  source = "./modules/vpc"
  providers = { aws = aws.use2 }
  name      = "${var.project_name}-us-east-2"
  vpc_cidr = var.vpc_cidrs["us-east-2"]
  az_count = var.az_count
  ssh_ip_range          = var.ssh_ip_range
  allowed_inbound_cidrs = local.all_enabled_vpc_cidrs
  pgb_port = var.pgb_port
  db_port = var.db_port
  ui_port = var.ui_port
  project_tags = merge(var.project_tags, { Region = "us-east-2" })
}

module "vpc_us_west_1" {
  count = contains(var.enabled_regions, "us-west-1") ? 1 : 0
  source = "./modules/vpc"
  providers = { aws = aws.usw1 }
  name      = "${var.project_name}-us-west-1"
  vpc_cidr = var.vpc_cidrs["us-west-1"]
  az_count = var.az_count
  ssh_ip_range          = var.ssh_ip_range
  allowed_inbound_cidrs = local.all_enabled_vpc_cidrs
  pgb_port = var.pgb_port
  db_port = var.db_port
  ui_port = var.ui_port
  project_tags = merge(var.project_tags, { Region = "us-west-1" })
}

module "vpc_us_west_2" {
  count = contains(var.enabled_regions, "us-west-2") ? 1 : 0
  source = "./modules/vpc"
  providers = { aws = aws.usw2 }
  name      = "${var.project_name}-us-west-2"
  vpc_cidr = var.vpc_cidrs["us-west-2"]
  az_count = var.az_count
  ssh_ip_range          = var.ssh_ip_range
  allowed_inbound_cidrs = local.all_enabled_vpc_cidrs
  pgb_port = var.pgb_port
  db_port = var.db_port
  ui_port = var.ui_port
  project_tags = merge(var.project_tags, { Region = "us-west-2" })
}

module "cockroach_us_east_1" {
  count  = contains(var.enabled_regions, "us-east-1") ? 1 : 0
  source = "./modules/cockroach"

  providers = {
    aws = aws.use1
  }

  name               = var.project_name
  region             = "us-east-1"
  dns_zone           = var.dns_zone
  azs                = module.vpc_us_east_1[0].availability_zones
  subnet_ids         = module.vpc_us_east_1[0].public_subnet_ids
  security_group_id  = module.vpc_us_east_1[0].node_security_group_id
  
  nodes_per_region   = var.nodes_per_region
  instance_type      = local.selected_cluster.instance_type

  disk_size_gb       = var.cockroach_disk_size_gb
  disk_type          = var.cockroach_disk_type
  disk_iops          = var.cockroach_disk_iops
  disk_throughput    = var.cockroach_disk_throughput

  cockroach_version  = var.cockroach_version
  architecture       = local.selected_cluster.instance_architecture

  vm_user            = var.vm_user
  ssh_key_name       = var.ssh_key_name
  ssh_key            = var.ssh_public_key

  tags               = var.project_tags
}

module "cockroach_us_east_2" {
  count  = contains(var.enabled_regions, "us-east-2") ? 1 : 0
  source = "./modules/cockroach"

  providers = {
    aws = aws.use2
  }

  name               = var.project_name
  region             = "us-east-2"
  dns_zone           = var.dns_zone
  azs                = module.vpc_us_east_2[0].availability_zones
  subnet_ids         = module.vpc_us_east_2[0].public_subnet_ids
  security_group_id  = module.vpc_us_east_2[0].node_security_group_id
  
  nodes_per_region   = var.nodes_per_region
  instance_type      = local.selected_cluster.instance_type

  disk_size_gb       = var.cockroach_disk_size_gb
  disk_type          = var.cockroach_disk_type
  disk_iops          = var.cockroach_disk_iops
  disk_throughput    = var.cockroach_disk_throughput

  cockroach_version  = var.cockroach_version
  architecture       = local.selected_cluster.instance_architecture

  vm_user            = var.vm_user
  ssh_key_name       = var.ssh_key_name
  ssh_key            = var.ssh_public_key

  tags               = var.project_tags
}

module "cockroach_us_west_1" {
  count  = contains(var.enabled_regions, "us-west-1") ? 1 : 0
  source = "./modules/cockroach"

  providers = {
    aws = aws.usw1
  }

  name               = var.project_name
  region             = "us-west-1"
  dns_zone           = var.dns_zone
  azs                = module.vpc_us_west_1[0].availability_zones
  subnet_ids         = module.vpc_us_west_1[0].public_subnet_ids
  security_group_id  = module.vpc_us_west_1[0].node_security_group_id
  
  nodes_per_region   = var.nodes_per_region
  instance_type      = local.selected_cluster.instance_type

  disk_size_gb       = var.cockroach_disk_size_gb
  disk_type          = var.cockroach_disk_type
  disk_iops          = var.cockroach_disk_iops
  disk_throughput    = var.cockroach_disk_throughput

  cockroach_version  = var.cockroach_version
  architecture       = local.selected_cluster.instance_architecture

  vm_user            = var.vm_user
  ssh_key_name       = var.ssh_key_name
  ssh_key            = var.ssh_public_key

  tags               = var.project_tags
}

module "cockroach_us_west_2" {
  count  = contains(var.enabled_regions, "us-west-2") ? 1 : 0
  source = "./modules/cockroach"

  providers = {
    aws = aws.usw2
  }

  name               = var.project_name
  region             = "us-west-2"
  dns_zone           = var.dns_zone
  azs                = module.vpc_us_west_2[0].availability_zones
  subnet_ids         = module.vpc_us_west_2[0].public_subnet_ids
  security_group_id  = module.vpc_us_west_2[0].node_security_group_id
  
  nodes_per_region   = var.nodes_per_region
  instance_type      = local.selected_cluster.instance_type

  disk_size_gb       = var.cockroach_disk_size_gb
  disk_type          = var.cockroach_disk_type
  disk_iops          = var.cockroach_disk_iops
  disk_throughput    = var.cockroach_disk_throughput

  cockroach_version  = var.cockroach_version
  architecture       = local.selected_cluster.instance_architecture

  vm_user            = var.vm_user
  ssh_key_name       = var.ssh_key_name
  ssh_key            = var.ssh_public_key

  tags               = var.project_tags
}

module "dcp_us_east_1" {
  count  = contains(var.enabled_regions, "us-east-1") ? 1 : 0
  source = "./modules/dcp"

  providers = {
    aws = aws.use1
  }

  name              = var.project_name
  region            = "us-east-1"
  dns_zone          = var.dns_zone
  subnet_id         = module.vpc_us_east_1[0].public_subnet_ids[0]
  security_group_id = module.vpc_us_east_1[0].proxy_security_group_id

  backend_nodes = module.cockroach_us_east_1[0].private_ips

  architecture  = var.proxy_defaults.instance_architecture
  instance_type = var.proxy_defaults.instance_type

  vm_user       = var.vm_user
  ssh_key       = var.ssh_public_key
  ssh_key_name  = var.ssh_key_name

  tags          = var.project_tags

  ha_node_count = var.ha_node_count
  pgb_port      = var.pgb_port
  db_port       = var.db_port
}

module "dcp_us_east_2" {
  count  = contains(var.enabled_regions, "us-east-2") ? 1 : 0
  source = "./modules/dcp"

  providers = {
    aws = aws.use2
  }

  name              = var.project_name
  region            = "us-east-2"
  dns_zone          = var.dns_zone
  subnet_id         = module.vpc_us_east_2[0].public_subnet_ids[0]
  security_group_id = module.vpc_us_east_2[0].proxy_security_group_id

  backend_nodes = module.cockroach_us_east_2[0].private_ips

  architecture  = var.proxy_defaults.instance_architecture
  instance_type = var.proxy_defaults.instance_type

  vm_user       = var.vm_user
  ssh_key       = var.ssh_public_key
  ssh_key_name  = var.ssh_key_name

  tags          = var.project_tags

  ha_node_count = var.ha_node_count
  pgb_port      = var.pgb_port
  db_port       = var.db_port
}

module "dcp_us_west_1" {
  count  = contains(var.enabled_regions, "us-west-1") ? 1 : 0
  source = "./modules/dcp"

  providers = {
    aws = aws.usw1
  }

  name              = var.project_name
  region            = "us-west-1"
  dns_zone          = var.dns_zone
  subnet_id         = module.vpc_us_west_1[0].public_subnet_ids[0]
  security_group_id = module.vpc_us_west_1[0].proxy_security_group_id

  backend_nodes = module.cockroach_us_west_1[0].private_ips

  architecture  = var.proxy_defaults.instance_architecture
  instance_type = var.proxy_defaults.instance_type

  vm_user       = var.vm_user
  ssh_key       = var.ssh_public_key
  ssh_key_name  = var.ssh_key_name

  tags          = var.project_tags

  ha_node_count = var.ha_node_count
  pgb_port      = var.pgb_port
  db_port       = var.db_port
}

module "dcp_us_west_2" {
  count  = contains(var.enabled_regions, "us-west-2") ? 1 : 0
  source = "./modules/dcp"

  providers = {
    aws = aws.usw2
  }

  name              = var.project_name
  region            = "us-west-2"
  dns_zone          = var.dns_zone
  subnet_id         = module.vpc_us_west_2[0].public_subnet_ids[0]
  security_group_id = module.vpc_us_west_2[0].proxy_security_group_id

  backend_nodes = module.cockroach_us_west_2[0].private_ips

  architecture  = var.proxy_defaults.instance_architecture
  instance_type = var.proxy_defaults.instance_type

  vm_user       = var.vm_user
  ssh_key       = var.ssh_public_key
  ssh_key_name  = var.ssh_key_name

  tags          = var.project_tags

  ha_node_count = var.ha_node_count
  pgb_port      = var.pgb_port
  db_port       = var.db_port
}
