ARM_SUBSCRIPTION_ID="{{.Values.global.subscriptionId}}"
ARM_TENANT_ID="{{.Values.global.tenantId}}"
ARM_CLIENT_SECRET="{{.Values.terraform.spn.appId}}"
ARM_CLIENT_ID="{{.Values.terraform.spn.pwd}}"

resource_group_name="{{.Values.aks.resourceGroup}}"
resource_group_location="{{.Values.aks.location}}"
cluster_name="{{.Values.aks.clusterName}}"
agent_vm_count = "{{.Values.aks.nodeCount}}"
agent_vm_size = "{{.Values.aks.vmSize}}"
dns_prefix="{{.Values.aks.dnsPrefix}}"
server_app_id=""
server_app_secret=""
client_app_id=""
tenant_id=""
service_principal_id = "{{.Values.terraform.spn.appId}}"
service_principal_secret = "{{.Values.terraform.spn.pwd}}"
ssh_public_key = "{{.Values.aks.nodePublicSshKey}}"
gitops_ssh_url = "{{.Values.flux.repo}}"
gitops_ssh_key = "{{.Values.flux.deployPrivateKeyFile}}"
vnet_name = "{{.Values.aks.virtualNetwork}}"

#--------------------------------------------------------------
# Optional variables - Uncomment to use
#--------------------------------------------------------------
# gitops_url_branch = "release-123"
# gitops_poll_interval = "30s"
# gitops_path = "prod"
# network_policy = "calico"
# oms_agent_enabled = "false"
