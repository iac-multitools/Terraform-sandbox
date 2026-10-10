output "resource_group_name" {
  value = data.azurerm_resource_group.main.name
}

output "website_url" {
  description = "Public URL of the static website."
  value       = azurerm_storage_account.site.primary_web_endpoint
}
