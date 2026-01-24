output "nodes" {
  value = [
    for i, inst in aws_instance.crdb : {
      index      = i
      id         = inst.id
      name       = inst.tags["Name"]
      private_ip = inst.private_ip
      public_ip  = inst.public_ip
      public_dns = inst.public_dns
      az         = inst.availability_zone
    }
  ]
}

output "private_ips" {
  value = aws_instance.crdb[*].private_ip
}

output "node_records" {
  description = "Per-node DNS and IP records for Route53"
  value = [
    for i, inst in aws_instance.crdb : {
      name       = "crdb-n${i}.${var.region}.${var.dns_zone}"
      private_ip = inst.private_ip
      public_dns = inst.public_dns
      az         = inst.availability_zone
    }
  ]
}
