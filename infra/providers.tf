# Authentication comes from environment variables, so nothing secret lives in code:
#   - Locally:  `az login` + ARM_SUBSCRIPTION_ID
#   - CI:       ARM_CLIENT_ID / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID + ARM_USE_OIDC=true
provider "azurerm" {
  features {}

  # By default the provider tries to register Azure resource providers at SUBSCRIPTION
  # scope, which our RG-scoped identity isn't allowed to do. Bootstrap registers them instead.
  resource_provider_registrations = "none"
}
