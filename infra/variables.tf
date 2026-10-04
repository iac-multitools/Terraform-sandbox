variable "resource_group_name" {
  description = "Existing resource group to deploy into (created by bootstrap). Resources inherit its region."
  type        = string
}

variable "prefix" {
  description = "Short name used as a prefix for every resource."
  type        = string
  default     = "sandbox"
}

variable "vm_size" {
  description = "VM size. Standard_B1s is cheap and free-tier eligible."
  type        = string
  default     = "Standard_B1s"
}

variable "admin_username" {
  description = "Admin user created on the VM."
  type        = string
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "SSH public key contents (e.g. the text of ~/.ssh/id_rsa.pub)."
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to the VM, e.g. \"203.0.113.10/32\" (your home IP)."
  type        = string
}

variable "auto_shutdown_time" {
  description = "Daily auto-shutdown time (HHMM, UTC) to save money."
  type        = string
  default     = "1900"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    managed_by = "terraform"
    purpose    = "learning"
  }
}
