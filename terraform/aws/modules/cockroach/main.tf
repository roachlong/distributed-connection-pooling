data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"] # Debian

  filter {
    name   = "name"
    values = ["debian-12-${var.architecture}-*"]
  }
}

# IAM role for CockroachDB instances to access S3 for imports, backups, and audit logs
# Only create if existing_iam_instance_profile_name is not provided
resource "aws_iam_role" "crdb" {
  count                = var.existing_iam_instance_profile_name == "" ? 1 : 0
  name                 = "${var.name}-${var.region}-crdb-role"
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# S3 access policy for IMPORT, BACKUP, and audit logs
resource "aws_iam_role_policy" "crdb_s3" {
  count = var.existing_iam_instance_profile_name == "" && length(var.s3_bucket_arns) > 0 ? 1 : 0
  name  = "${var.name}-${var.region}-crdb-s3-policy"
  role  = aws_iam_role.crdb[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3AccessForImportsBackupsAudits"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = concat(
          var.s3_bucket_arns,
          [for arn in var.s3_bucket_arns : "${arn}/*"]
        )
      }
    ]
  })
}

resource "aws_iam_instance_profile" "crdb" {
  count = var.existing_iam_instance_profile_name == "" ? 1 : 0
  name  = "${var.name}-${var.region}-crdb-profile"
  role  = aws_iam_role.crdb[0].name
}

# Data source to look up existing instance profile if provided
data "aws_iam_instance_profile" "existing" {
  count = var.existing_iam_instance_profile_name != "" ? 1 : 0
  name  = var.existing_iam_instance_profile_name
}

# Local to determine which instance profile to use
locals {
  instance_profile_name = var.existing_iam_instance_profile_name != "" ? data.aws_iam_instance_profile.existing[0].name : aws_iam_instance_profile.crdb[0].name
}

resource "aws_instance" "crdb" {
  count = var.nodes_per_region

  ami                    = data.aws_ami.debian.id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_for_node[count.index]
  vpc_security_group_ids = [var.security_group_id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = local.instance_profile_name

  root_block_device {
    encrypted  = var.kms_key_id != "" ? true : false
    kms_key_id = var.kms_key_id != "" ? var.kms_key_id : null
  }

  user_data = templatefile("${path.module}/cloud-init.tpl.yml",
    {
      node_index        = count.index
      region            = var.region
      az                = local.az_for_node[count.index]
      cockroach_version = var.cockroach_version
      architecture      = var.architecture
      vm_user           = var.vm_user
      ssh_key           = var.ssh_key
    }
  )

  tags = merge(
    var.tags,
    {
      Name   = "${var.name}-${var.region}-n${count.index}"
      Region = var.region
      AZ     = local.az_for_node[count.index]
      Role   = "cockroach"
    }
  )
}

resource "aws_ebs_volume" "data" {
  count = var.nodes_per_region

  availability_zone = aws_instance.crdb[count.index].availability_zone
  size              = var.disk_size_gb
  type              = var.disk_type

  iops       = var.disk_type == "io1" || var.disk_type == "io2" ? var.disk_iops : null
  throughput = var.disk_type == "gp3" ? var.disk_throughput : null

  encrypted  = var.kms_key_id != "" ? true : false
  kms_key_id = var.kms_key_id != "" ? var.kms_key_id : null

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-${var.region}-data-${count.index}"
      Role = "cockroach-data"
    }
  )
}

resource "aws_volume_attachment" "data" {
  count = var.nodes_per_region

  device_name = "/dev/sdp"
  volume_id   = aws_ebs_volume.data[count.index].id
  instance_id = aws_instance.crdb[count.index].id

  force_detach = true
}
