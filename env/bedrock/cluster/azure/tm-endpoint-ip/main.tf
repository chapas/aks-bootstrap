resource "azurerm_public_ip" "pip" {
  name = "${var.public_ip_name}"
  location = "${var.resource_location}"
  resource_group_name = "${var.resource_group_name}"
  allocation_method = "Static"
  domain_name_label = "${var.public_ip_name}-dns"
  tags = "${var.tags}"
}

resource "azurerm_traffic_manager_endpoint" "endpoint" {
  name = "${var.endpoint_name}-ep"
  resource_group_name = "${var.traffic_manager_resource_group_name}"
  profile_name = "${var.traffic_manager_profile_name}"
  target_resource_id = "${azurerm_public_ip.pip.id}"
  type = "azureEndpoints"
  weight = 1
}

resource "null_resource" "ip_address" {
  count = "${var.ipaddress_to_disk ? 1 : 0}"

  provisioner "local-exec" {
    command = "if [ ! -e ${var.output_directory} ]; then mkdir -p ${var.output_directory}; fi && echo ${azurerm_public_ip.pip.ip_address} > ${var.output_directory}/${var.ip_address_out_filename}"
  }

  triggers {
    ipaddress_to_disk = "${var.ipaddress_to_disk}"
  }

  depends_on = ["${azurerm_public_ip.pip}"]
}

