# ---------- Experiment: static website on a storage account ----------
# A storage account can serve files from its special "$web" container as a website.
# Cost: a few cents a month at most for a single small file.

# Storage account names must be globally unique across Azure (3-24 lowercase letters/digits),
# so add a random suffix. It's generated once and then stored in state, so it stays stable.
resource "random_string" "site_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_storage_account" "site" {
  name                     = "st${var.prefix}web${random_string.site_suffix.result}"
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = data.azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = var.tags
}

# Turns on static website hosting, which creates the "$web" container.
resource "azurerm_storage_account_static_website" "site" {
  storage_account_id = azurerm_storage_account.site.id
  index_document     = "index.html"
  error_404_document = "index.html"
}

resource "azurerm_storage_blob" "index" {
  name                 = "index.html"
  storage_container_id = "${azurerm_storage_account.site.id}/blobServices/default/containers/$web"
  type                 = "Block"
  content_type         = "text/html"

  # Render the template with values from Terraform. Edit site/index.html.tftpl and the
  # next plan shows this blob as an in-place update.
  source_content = templatefile("${path.module}/site/index.html.tftpl", {
    resource_group  = data.azurerm_resource_group.main.name
    location        = data.azurerm_resource_group.main.location
    storage_account = azurerm_storage_account.site.name
  })

  # "$web" only exists once static website hosting is on. Terraform can't infer that from
  # references above, so state the dependency explicitly.
  depends_on = [azurerm_storage_account_static_website.site]
}
