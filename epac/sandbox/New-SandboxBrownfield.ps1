<#
.SYNOPSIS
    SANDBOX ONLY. Builds a small "existing estate" for EPAC to export and adopt.

.DESCRIPTION
    Not part of EPAC, and never run at Landgate, which already has its hierarchy and policies.
    This creates what Landgate already has, so the export step has something real to export:

      Tenant Root Group
      ├── mg-landgate-sim   (EPAC "tenant" environment)
      │   └── Pay-As-You-Go subscription
      └── mg-epac-dev       (EPAC "epac-dev" environment, empty)

    Then, at mg-landgate-sim, creates policy the "old" way (by hand, no EPAC):
      - custom definition  "legacy-audit-rg-environment-tag" (Audit resource groups without an Environment tag)
      - assignment         "legacy-rg-env-tag"   -> the custom definition
      - assignment         "legacy-allowed-locs" -> built-in "Allowed locations" (australiaeast, australiasoutheast)

    Safe to re-run. Requires PowerShell 7 + Az, signed in with Connect-AzAccount as subscription Owner.
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = 'e0e05915-ccc9-4b6d-a340-25412753cd66'
)
$ErrorActionPreference = 'Stop'

# --- Management groups -------------------------------------------------------
foreach ($mg in 'mg-landgate-sim', 'mg-epac-dev') {
    if (-not (Get-AzManagementGroup -GroupName $mg -ErrorAction SilentlyContinue)) {
        Write-Host "Creating management group $mg"
        New-AzManagementGroup -GroupName $mg -DisplayName $mg | Out-Null
    }
}
Write-Host "Moving subscription under mg-landgate-sim"
New-AzManagementGroupSubscription -GroupName 'mg-landgate-sim' -SubscriptionId $SubscriptionId

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

Write-Host "Assigning legacy-allowed-locs"
$allowedLocations = Get-AzPolicyDefinition -Id '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'
New-AzPolicyAssignment -Name 'legacy-allowed-locs' -Scope $scope `
    -DisplayName 'Allowed locations (Australia)' `
    -PolicyDefinition $allowedLocations `
    -PolicyParameterObject @{ listOfAllowedLocations = @('australiaeast', 'australiasoutheast') } | Out-Null

Write-Host "Done. Pre-EPAC policy at ${scope}:"
Get-AzPolicyAssignment -Scope $scope | Select-Object Name, @{ n = 'DisplayName'; e = { $_.DisplayName } } | Format-Table
