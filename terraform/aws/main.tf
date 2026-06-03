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
  subnet_ids         = module.vpc_us_east_1[0].private_subnet_ids
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

  s3_bucket_arns                      = local.crdb_s3_bucket_arns
  permissions_boundary_arn            = var.permissions_boundary_arn
  kms_key_id                          = contains(var.enabled_regions, "us-east-1") ? aws_kms_key.crdb_ebs_use1[0].arn : ""
  existing_iam_instance_profile_name  = var.existing_iam_instance_profile_name

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
  subnet_ids         = module.vpc_us_east_2[0].private_subnet_ids
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

  s3_bucket_arns                      = local.crdb_s3_bucket_arns
  permissions_boundary_arn            = var.permissions_boundary_arn
  kms_key_id                          = contains(var.enabled_regions, "us-east-2") ? aws_kms_key.crdb_ebs_use2[0].arn : ""
  existing_iam_instance_profile_name  = var.existing_iam_instance_profile_name

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
  subnet_ids         = module.vpc_us_west_1[0].private_subnet_ids
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

  s3_bucket_arns                      = local.crdb_s3_bucket_arns
  permissions_boundary_arn            = var.permissions_boundary_arn
  kms_key_id                          = contains(var.enabled_regions, "us-west-1") ? aws_kms_key.crdb_ebs_usw1[0].arn : ""
  existing_iam_instance_profile_name  = var.existing_iam_instance_profile_name

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
  subnet_ids         = module.vpc_us_west_2[0].private_subnet_ids
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

  s3_bucket_arns                      = local.crdb_s3_bucket_arns
  permissions_boundary_arn            = var.permissions_boundary_arn
  kms_key_id                          = contains(var.enabled_regions, "us-west-2") ? aws_kms_key.crdb_ebs_usw2[0].arn : ""
  existing_iam_instance_profile_name  = var.existing_iam_instance_profile_name

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
  permissions_boundary_arn            = var.permissions_boundary_arn
  existing_iam_instance_profile_name  = var.existing_iam_instance_profile_name

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
  permissions_boundary_arn            = var.permissions_boundary_arn
  existing_iam_instance_profile_name  = var.existing_iam_instance_profile_name

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
  permissions_boundary_arn            = var.permissions_boundary_arn
  existing_iam_instance_profile_name  = var.existing_iam_instance_profile_name

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
  permissions_boundary_arn            = var.permissions_boundary_arn
  existing_iam_instance_profile_name  = var.existing_iam_instance_profile_name

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

# ==============================================================================
# Bastion Hosts (one per region for SSH access to private instances)
# ==============================================================================

module "bastion_us_east_1" {
  count  = contains(var.enabled_regions, "us-east-1") ? 1 : 0
  source = "./modules/bastion"

  providers = {
    aws = aws.use1
  }

  name              = var.project_name
  region            = "us-east-1"
  vpc_id            = module.vpc_us_east_1[0].vpc_id
  public_subnet_id  = module.vpc_us_east_1[0].public_subnet_ids[0]
  ssh_key_name      = var.ssh_key_name
  ssh_ip_range      = var.ssh_ip_range
  vm_user           = var.vm_user
  ssh_key           = var.ssh_public_key

  tags = var.project_tags
}

module "bastion_us_east_2" {
  count  = contains(var.enabled_regions, "us-east-2") ? 1 : 0
  source = "./modules/bastion"

  providers = {
    aws = aws.use2
  }

  name              = var.project_name
  region            = "us-east-2"
  vpc_id            = module.vpc_us_east_2[0].vpc_id
  public_subnet_id  = module.vpc_us_east_2[0].public_subnet_ids[0]
  ssh_key_name      = var.ssh_key_name
  ssh_ip_range      = var.ssh_ip_range
  vm_user           = var.vm_user
  ssh_key           = var.ssh_public_key

  tags = var.project_tags
}

module "bastion_us_west_1" {
  count  = contains(var.enabled_regions, "us-west-1") ? 1 : 0
  source = "./modules/bastion"

  providers = {
    aws = aws.usw1
  }

  name              = var.project_name
  region            = "us-west-1"
  vpc_id            = module.vpc_us_west_1[0].vpc_id
  public_subnet_id  = module.vpc_us_west_1[0].public_subnet_ids[0]
  ssh_key_name      = var.ssh_key_name
  ssh_ip_range      = var.ssh_ip_range
  vm_user           = var.vm_user
  ssh_key           = var.ssh_public_key

  tags = var.project_tags
}

module "bastion_us_west_2" {
  count  = contains(var.enabled_regions, "us-west-2") ? 1 : 0
  source = "./modules/bastion"

  providers = {
    aws = aws.usw2
  }

  name              = var.project_name
  region            = "us-west-2"
  vpc_id            = module.vpc_us_west_2[0].vpc_id
  public_subnet_id  = module.vpc_us_west_2[0].public_subnet_ids[0]
  ssh_key_name      = var.ssh_key_name
  ssh_ip_range      = var.ssh_ip_range
  vm_user           = var.vm_user
  ssh_key           = var.ssh_public_key

  tags = var.project_tags
}

# ==============================================================================
# S3 Buckets for CRDB Imports, Backups, and Audit Logs
# ==============================================================================

resource "aws_s3_bucket" "crdb_imports" {
  bucket = "${var.project_name}-crdb-imports"

  tags = merge(var.project_tags, {
    Name    = "${var.project_name}-crdb-imports"
    Purpose = "CRDB IMPORT data landing zone"
  })
}

resource "aws_s3_bucket_versioning" "crdb_imports" {
  bucket = aws_s3_bucket.crdb_imports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "crdb_imports" {
  bucket = aws_s3_bucket.crdb_imports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "crdb_imports" {
  bucket = aws_s3_bucket.crdb_imports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "crdb_backups" {
  bucket = "${var.project_name}-crdb-backups"

  tags = merge(var.project_tags, {
    Name    = "${var.project_name}-crdb-backups"
    Purpose = "CRDB automated backups"
  })
}

resource "aws_s3_bucket_versioning" "crdb_backups" {
  bucket = aws_s3_bucket.crdb_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "crdb_backups" {
  bucket = aws_s3_bucket.crdb_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "crdb_backups" {
  bucket = aws_s3_bucket.crdb_backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_public_access_block" "crdb_backups" {
  bucket = aws_s3_bucket.crdb_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "crdb_audit_logs" {
  bucket = "${var.project_name}-crdb-audit-logs"

  tags = merge(var.project_tags, {
    Name    = "${var.project_name}-crdb-audit-logs"
    Purpose = "CRDB audit logs for compliance"
  })
}

resource "aws_s3_bucket_versioning" "crdb_audit_logs" {
  bucket = aws_s3_bucket.crdb_audit_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "crdb_audit_logs" {
  bucket = aws_s3_bucket.crdb_audit_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "crdb_audit_logs" {
  bucket = aws_s3_bucket.crdb_audit_logs.id

  rule {
    id     = "retain-audit-logs"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 2555  # 7 years for compliance
    }
  }
}

resource "aws_s3_bucket_public_access_block" "crdb_audit_logs" {
  bucket = aws_s3_bucket.crdb_audit_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==============================================================================
# KMS Keys for EBS Encryption (one per region)
# ==============================================================================

resource "aws_kms_key" "crdb_ebs_use1" {
  count               = contains(var.enabled_regions, "us-east-1") ? 1 : 0
  provider            = aws.use1
  description         = "KMS key for CockroachDB EBS volumes in us-east-1"
  enable_key_rotation = true

  tags = merge(var.project_tags, {
    Name   = "${var.project_name}-crdb-ebs-use1"
    Region = "us-east-1"
  })
}

resource "aws_kms_alias" "crdb_ebs_use1" {
  count         = contains(var.enabled_regions, "us-east-1") ? 1 : 0
  provider      = aws.use1
  name          = "alias/${var.project_name}-crdb-ebs-use1"
  target_key_id = aws_kms_key.crdb_ebs_use1[0].key_id
}

resource "aws_kms_key" "crdb_ebs_use2" {
  count               = contains(var.enabled_regions, "us-east-2") ? 1 : 0
  provider            = aws.use2
  description         = "KMS key for CockroachDB EBS volumes in us-east-2"
  enable_key_rotation = true

  tags = merge(var.project_tags, {
    Name   = "${var.project_name}-crdb-ebs-use2"
    Region = "us-east-2"
  })
}

resource "aws_kms_alias" "crdb_ebs_use2" {
  count         = contains(var.enabled_regions, "us-east-2") ? 1 : 0
  provider      = aws.use2
  name          = "alias/${var.project_name}-crdb-ebs-use2"
  target_key_id = aws_kms_key.crdb_ebs_use2[0].key_id
}

resource "aws_kms_key" "crdb_ebs_usw1" {
  count               = contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider            = aws.usw1
  description         = "KMS key for CockroachDB EBS volumes in us-west-1"
  enable_key_rotation = true

  tags = merge(var.project_tags, {
    Name   = "${var.project_name}-crdb-ebs-usw1"
    Region = "us-west-1"
  })
}

resource "aws_kms_alias" "crdb_ebs_usw1" {
  count         = contains(var.enabled_regions, "us-west-1") ? 1 : 0
  provider      = aws.usw1
  name          = "alias/${var.project_name}-crdb-ebs-usw1"
  target_key_id = aws_kms_key.crdb_ebs_usw1[0].key_id
}

resource "aws_kms_key" "crdb_ebs_usw2" {
  count               = contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider            = aws.usw2
  description         = "KMS key for CockroachDB EBS volumes in us-west-2"
  enable_key_rotation = true

  tags = merge(var.project_tags, {
    Name   = "${var.project_name}-crdb-ebs-usw2"
    Region = "us-west-2"
  })
}

resource "aws_kms_alias" "crdb_ebs_usw2" {
  count         = contains(var.enabled_regions, "us-west-2") ? 1 : 0
  provider      = aws.usw2
  name          = "alias/${var.project_name}-crdb-ebs-usw2"
  target_key_id = aws_kms_key.crdb_ebs_usw2[0].key_id
}
