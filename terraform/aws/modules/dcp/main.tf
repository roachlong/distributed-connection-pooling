data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"] # Debian
  filter {
    name   = "name"
    values = ["debian-12-${var.architecture}-*"]
  }
}

resource "aws_eip" "dcp" {
  tags = merge(var.tags, { Name = "${var.name}-${var.region}-dcp-eip" })
}

# Associate initially to the first DCP instance (keepalived will move it later)
resource "aws_eip_association" "dcp_initial" {
  allocation_id = aws_eip.dcp.id
  instance_id   = aws_instance.dcp_node[0].id
}

# IAM role/profile for ENI operations (Keepalived needs to be able to attach/unattach VIP)
data "aws_iam_policy_document" "instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# resource "aws_iam_role" "eni_role" {
#   name               = "${var.name}-${var.region}-eni-role"
#   assume_role_policy = data.aws_iam_policy_document.instance_assume.json
# }

# resource "aws_iam_role_policy" "eni_policy" {
#   name = "${var.name}-${var.region}-eni-policy"
#   role = aws_iam_role.eni_role.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Effect = "Allow"
#       Action = [
#         "ec2:AssignPrivateIpAddresses",
#         "ec2:UnassignPrivateIpAddresses",
#         "ec2:DescribeNetworkInterfaces",
#         "ec2:DescribeInstances",
#         "ec2:AssociateAddress",
#         "ec2:DisassociateAddress",
#         "ec2:DescribeAddresses"
#       ]
#       Resource = "*"
#     }]
#   })
# }

# resource "aws_iam_instance_profile" "eni_profile" {
#   name = "${aws_iam_role.eni_role.name}-profile"
#   role = aws_iam_role.eni_role.name
# }

# Network Interface used as VIP holder (private IP specified in tfvars or left to provider)
resource "aws_network_interface" "vip_eni" {
  subnet_id   = var.subnet_id
  description = "dcp-vip-eni-${var.region}"
  tags = merge(var.tags, { Name = "dcp-vip-eni-${var.region}" })
}

# Simple EC2 instances for the DCP machines (2 recommended)
resource "aws_instance" "dcp_node" {
  count         = var.ha_node_count
  ami           = data.aws_ami.debian.id
  instance_type = var.instance_type
  subnet_id     = element([var.subnet_id], 0)
  vpc_security_group_ids = [var.security_group_id]
  key_name      = var.ssh_key_name
  # iam_instance_profile = aws_iam_instance_profile.eni_profile.name

  user_data = templatefile("${path.module}/cloud-init.tpl.yml", {
    name               = var.name
    region             = var.region
    vm_user            = var.vm_user
    ssh_key            = var.ssh_key
    dns_zone           = var.dns_zone
    db_port            = var.db_port
    pgb_port           = var.pgb_port
    vip_private_ip     = aws_network_interface.vip_eni.private_ip
    eip_allocation_id  = aws_eip.dcp.id

    claim_eip_sh         = file("${path.module}/files/claim-eip.sh")
    start_pgbouncer_sh   = file("${path.module}/files/start-pgbouncer.sh")
    pgbouncer_template   = file("${path.module}/files/pgbouncer.template")
  })

  tags = merge(var.tags, { Name = "${var.name}-${var.region}-dcp-${count.index+1}" })
}
