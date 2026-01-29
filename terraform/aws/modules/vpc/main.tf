# Discover available AZs in *this* provider's region.
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Component = "vpc"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Component = "igw"
  })
}

# Public subnets (one per AZ).
resource "aws_subnet" "public" {
  for_each = { for idx, az in local.azs : az => idx }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, var.public_subnet_newbits, each.value)
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Component = "subnet-public"
    AZ        = each.key
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, {
    Component = "rt-public"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets_by_az

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Component = "subnet-private"
    AZ        = each.key
  })
}

# Private route table (no internet route; TGW routes get added at top-level)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Component = "rt-private"
  })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# Node SG (unchanged)
resource "aws_security_group" "node" {
  count       = var.create_node_security_group ? 1 : 0
  name        = "${var.name}-node-sg"
  description = "Node SG: SSH + Cockroach ports"
  vpc_id      = aws_vpc.this.id

  # SSH from a public IP/CIDR
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ip_range]
  }

  # CockroachDB SQL/KV (node-to-node)
  ingress {
    description = "CockroachDB (SQL/KV)"
    from_port   = var.db_port
    to_port     = var.db_port
    protocol    = "tcp"
    cidr_blocks = local.inbound_cidrs
  }

  # CockroachDB Admin UI (optional, can be disabled by not using this SG or tightening CIDRs)
  ingress {
    description = "CockroachDB Admin UI"
    from_port   = var.ui_port
    to_port     = var.ui_port
    protocol    = "tcp"
    cidr_blocks = local.inbound_cidrs
  }

  # Allow all egress
  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Component = "sg-node"
  })
}

# Proxy SG to attach to DCP instances later
resource "aws_security_group" "proxy" {
  count       = var.create_proxy_security_group ? 1 : 0
  name        = "${var.name}-proxy-sg"
  description = "Proxy SG: SSH + DCP ports"
  vpc_id      = aws_vpc.this.id

  # SSH from a public IP/CIDR
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ip_range]
  }

  # SQL/PgBouncer Entry Point
  ingress {
    description = "SQL/PgBouncer Entry Point"
    from_port   = var.pgb_port
    to_port     = var.pgb_port
    protocol    = "tcp"
    cidr_blocks = concat(local.inbound_cidrs, [var.ssh_ip_range])
  }

  # CockroachDB SQL/KV (client and node-to-node)
  ingress {
    description = "CockroachDB (SQL/KV)"
    from_port   = var.db_port
    to_port     = var.db_port
    protocol    = "tcp"
    cidr_blocks = concat(local.inbound_cidrs, [var.ssh_ip_range])
  }

  # CockroachDB Admin UI
  ingress {
    description = "CockroachDB Admin UI"
    from_port   = var.ui_port
    to_port     = var.ui_port
    protocol    = "tcp"
    cidr_blocks = concat(local.inbound_cidrs, [var.ssh_ip_range])
  }

  # HAProxy Stats UI
  ingress {
    description = "HAProxy Stats UI"
    from_port   = 8404
    to_port     = 8404
    protocol    = "tcp"
    cidr_blocks = concat(local.inbound_cidrs, [var.ssh_ip_range])
  }

  # Allow all egress
  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Component = "sg-proxy"
  })
}
