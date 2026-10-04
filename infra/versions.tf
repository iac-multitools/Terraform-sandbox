terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Remote state lives in an Azure Storage Account created by bootstrap/bootstrap.ps1.
  # The actual values are in backend.hcl and passed with: terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}
