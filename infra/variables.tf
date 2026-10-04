variable "resource_group_name" {
  description = "Existing resource group to deploy into (created by bootstrap). Resources inherit its region."
  type        = string
}

variable "prefix" {
  description = "Short name used as a prefix for every resource."
  type        = string
  default     = "sandbox"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    managed_by = "terraform"
    purpose    = "learning"
  }
}
