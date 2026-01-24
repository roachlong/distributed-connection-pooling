output "vpc_id" {
  value       = aws_vpc.this.id
  description = "VPC ID."
}

output "vpc_cidr" {
  value       = aws_vpc.this.cidr_block
  description = "VPC CIDR."
}

output "availability_zones" {
  value       = local.azs
  description = "AZs used in this region."
}

output "public_subnet_ids" {
  value       = [for s in aws_subnet.public : s.id]
  description = "Public subnet IDs."
}

output "public_subnets" {
  value = {
    for az, s in aws_subnet.public : az => {
      id         = s.id
      cidr_block = s.cidr_block
      az         = s.availability_zone
    }
  }
  description = "Public subnet details keyed by AZ."
}

output "internet_gateway_id" {
  value       = aws_internet_gateway.this.id
  description = "IGW ID."
}

output "public_route_table_id" {
  value       = aws_route_table.public.id
  description = "Public route table ID."
}

output "node_security_group_id" {
  value       = var.create_node_security_group ? aws_security_group.node[0].id : null
  description = "Node SG ID (null if disabled)."
}

output "proxy_security_group_id" {
  value       = var.create_proxy_security_group ? aws_security_group.proxy[0].id : null
  description = "Proxy SG ID (null if disabled)."
}
