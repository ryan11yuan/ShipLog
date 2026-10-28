output "app_url" {
  value = "https://${azurerm_container_app.main.ingress[0].fqdn}"
}

output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "container_app_name" {
  value = azurerm_container_app.main.name
}

output "registry_name" {
  value = azurerm_container_registry.main.name
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}
