data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"] # Debian

  filter {
    name   = "name"
    values = ["debian-12-amd64-*"]
  }
}

resource "aws_security_group" "bastion" {
  name        = "${var.name}-bastion-sg"
  description = "Bastion host security group - SSH from trusted CIDR only"
  vpc_id      = var.vpc_id

  # SSH from trusted IP range only
  ingress {
    description = "SSH from trusted CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ip_range]
  }

  # Allow all outbound traffic
  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-bastion-sg"
    Component = "bastion"
  })
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.debian.id
  instance_type               = var.instance_type
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = var.ssh_key_name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/cloud-init.tpl.yml", {
    vm_user = var.vm_user
    ssh_key = var.ssh_key
  })

  tags = merge(var.tags, {
    Name      = "${var.name}-bastion"
    Component = "bastion"
    Region    = var.region
  })
}
