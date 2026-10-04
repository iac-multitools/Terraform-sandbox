# The resource group is created by bootstrap/bootstrap.ps1, not Terraform. The pipeline's
# identity only has rights INSIDE this RG, so Terraform references it as existing
# (like Bicep's `existing` keyword) and deploys into it.
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

# ---------- Networking ----------

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.prefix}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-${var.prefix}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  tags                = var.tags

  security_rule {
    name                       = "Allow-SSH-From-Me"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_public_ip" "vm" {
  name                = "pip-${var.prefix}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-${var.prefix}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

# ---------- Virtual machine ----------

resource "azurerm_linux_virtual_machine" "main" {
  name                  = "vm-${var.prefix}"
  location              = data.azurerm_resource_group.main.location
  resource_group_name   = data.azurerm_resource_group.main.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.vm.id]
  tags                  = var.tags

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# Shut the VM down every evening so a forgotten sandbox doesn't run up a bill.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "main" {
  virtual_machine_id    = azurerm_linux_virtual_machine.main.id
  location              = data.azurerm_resource_group.main.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = "UTC"
  tags                  = var.tags

  notification_settings {
    enabled = false
  }
}
