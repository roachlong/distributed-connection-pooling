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

output "public_route_table_id" {
  value       = aws_route_table.public.id
  description = "Public route table ID."
}

output "private_subnet_ids" {
  description = "Private subnet IDs (one per AZ), suitable for TGW attachments."
  value       = [for s in aws_subnet.private : s.id]
}

output "private_subnets_by_az" {
  description = "Map of AZ to private subnet ID."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "private_route_table_id" {
  description = "Private route table ID (TGW routes should target this too if instances use private subnets)."
  value       = aws_route_table.private.id
}

output "internet_gateway_id" {
  value       = aws_internet_gateway.this.id
  description = "IGW ID."
}

output "node_security_group_id" {
  value       = var.create_node_security_group ? aws_security_group.node[0].id : null
  description = "Node SG ID (null if disabled)."
}

output "proxy_security_group_id" {
  value       = var.create_proxy_security_group ? aws_security_group.proxy[0].id : null
  description = "Proxy SG ID (null if disabled)."
}
