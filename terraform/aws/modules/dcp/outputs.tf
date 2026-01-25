output "dcp_records" {
  value = [
    for idx, inst in aws_instance.dcp_node : {
      index          = idx
      id             = inst.id
      private_ip     = inst.private_ip
      public_ip      = inst.public_ip
      private_dns    = inst.private_dns
      public_dns     = inst.public_dns
      eip_public_ip  = aws_eip.dcp.public_ip
    }
  ]
}

output "vip_private_ip" {
  description = "Private VIP used for internal DNS and HAProxy ingress"
  value = aws_network_interface.vip_eni.private_ip
}

output "eip_public_ip" {
  value = aws_eip.dcp.public_ip
}

output "eip_allocation_id" {
  value = aws_eip.dcp.id
}
