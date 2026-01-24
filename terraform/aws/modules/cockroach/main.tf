data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"] # Debian

  filter {
    name   = "name"
    values = ["debian-12-${var.architecture}-*"]
  }
}

resource "aws_instance" "crdb" {
  count = var.nodes_per_region

  ami                    = data.aws_ami.debian.id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_for_node[count.index]
  vpc_security_group_ids = [var.security_group_id]
  key_name               = var.ssh_key_name

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
