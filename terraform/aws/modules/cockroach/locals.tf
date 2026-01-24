locals {
  az_for_node = [
    for i in range(var.nodes_per_region) :
    var.azs[i % length(var.azs)]
  ]

  subnet_for_node = [
    for i in range(var.nodes_per_region) :
    var.subnet_ids[i % length(var.subnet_ids)]
  ]
}
