<#
.SYNOPSIS
    SANDBOX ONLY. Builds a small "existing estate" for EPAC to export and adopt.

.DESCRIPTION
    Not part of EPAC, and never run at Landgate, which already has its hierarchy and policies.
    This creates what Landgate already has, so the export step has something real to export.

    LIGHT TOUCH: this tenant also runs a production app. Both management groups stay EMPTY and
    the subscription is NOT moved, so no policy here can reach any existing resource.

      Tenant Root Group
      ├── Pay-As-You-Go subscription   (untouched)
      ├── mg-landgate-sim              (EPAC "tenant" environment, empty)
      └── mg-epac-dev                  (EPAC "epac-dev" environment, empty)

    Then, at mg-landgate-sim, creates policy the "old" way (by hand, no EPAC). All Audit only:
      - custom definition  "legacy-audit-rg-environment-tag" (Audit resource groups without an Environment tag)
      - assignment         "legacy-rg-env-tag"         -> the custom definition
      - assignment         "legacy-storage-sharedkey"  -> built-in "Storage accounts should prevent shared key access" (Audit)

    Safe to re-run. Requires PowerShell 7 + Az, signed in with Connect-AzAccount.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# --- Management groups (empty) -------------------------------------------------
foreach ($mg in 'mg-landgate-sim', 'mg-epac-dev') {
    if (-not (Get-AzManagementGroup -GroupName $mg -ErrorAction SilentlyContinue)) {
        Write-Host "Creating management group $mg"
        New-AzManagementGroup -GroupName $mg -DisplayName $mg | Out-Null
    }
}

$scope = '/providers/Microsoft.Management/managementGroups/mg-landgate-sim'

# --- Custom policy definition ------------------------------------------------
$rule = @'
{
  "if": {
    "allOf": [
      { "field": "type", "equals": "Microsoft.Resources/subscriptions/resourceGroups" },
      { "field": "tags['Environment']", "exists": "false" }
    ]
  },
  "then": { "effect": "audit" }
}
'@
Write-Host "Creating custom definition legacy-audit-rg-environment-tag"
$definition = New-AzPolicyDefinition -Name 'legacy-audit-rg-environment-tag' `
    -ManagementGroupName 'mg-landgate-sim' `
    -DisplayName 'Audit resource groups without an Environment tag' `
    -Description 'Created by hand before EPAC (sandbox brownfield).' `
    -Metadata '{"category":"Tags"}' `
    -Mode All `
    -Policy $rule

# --- Assignments ---------------------------------------------------------------
Write-Host "Assigning legacy-rg-env-tag"
New-AzPolicyAssignment -Name 'legacy-rg-env-tag' -Scope $scope `
    -DisplayName 'Audit RG Environment tag' `
    -PolicyDefinition $definition | Out-Null

Write-Host "Assigning legacy-storage-sharedkey"
$sharedKey = Get-AzPolicyDefinition -Id '/providers/Microsoft.Authorization/policyDefinitions/8c6a50c6-9ffd-4ae7-986f-5fa6111f9a54'
New-AzPolicyAssignment -Name 'legacy-storage-sharedkey' -Scope $scope `
    -DisplayName 'Storage accounts should prevent shared key access' `
    -PolicyDefinition $sharedKey `
    -PolicyParameterObject @{ effect = 'Audit' } | Out-Null

Write-Host "Done. Pre-EPAC policy at ${scope}:"
Get-AzPolicyAssignment -Scope $scope | Select-Object Name, @{ n = 'DisplayName'; e = { $_.DisplayName } } | Format-Table
