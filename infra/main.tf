# The resource group is created by bootstrap/bootstrap.ps1, not Terraform. The pipeline's
# identity only has rights INSIDE this RG, so Terraform references it as existing
# (like Bicep's `existing` keyword) and deploys into it.
#
# Add experiments below (or in their own .tf files), using:
#   resource_group_name = data.azurerm_resource_group.main.name
#   location            = data.azurerm_resource_group.main.location
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}
