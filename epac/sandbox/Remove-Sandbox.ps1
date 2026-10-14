<#
.SYNOPSIS
    SANDBOX ONLY. Removes everything New-SandboxBrownfield.ps1 and EPAC created.

.DESCRIPTION
    Deletes every policy assignment and custom policy/policy set definition at both sandbox
    management groups (including any that EPAC deployed), moves the subscription back to the
    Tenant Root Group, and deletes the two management groups.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SubscriptionId = 'e0e05915-ccc9-4b6d-a340-25412753cd66',
    [string] $TenantId       = '1f5b14c6-0cbf-4012-931f-a1d26bcf0b3a'
)
$ErrorActionPreference = 'Stop'

foreach ($mg in 'mg-landgate-sim', 'mg-epac-dev') {
    if (-not (Get-AzManagementGroup -GroupName $mg -ErrorAction SilentlyContinue)) { continue }
    $scope = "/providers/Microsoft.Management/managementGroups/$mg"

    # Includes role assignments EPAC made for managed identities, which go with the assignment.
    Get-AzPolicyAssignment -Scope $scope | Where-Object { $_.Scope -eq $scope } | ForEach-Object {
        Write-Host "Removing assignment $($_.Name) at $mg"
        Remove-AzPolicyAssignment -Id $_.Id | Out-Null
    }
    Get-AzPolicySetDefinition -ManagementGroupName $mg -Custom | ForEach-Object {
        Write-Host "Removing policy set definition $($_.Name) at $mg"
        Remove-AzPolicySetDefinition -Id $_.Id -Force | Out-Null
    }
    Get-AzPolicyDefinition -ManagementGroupName $mg -Custom | ForEach-Object {
        Write-Host "Removing policy definition $($_.Name) at $mg"
        Remove-AzPolicyDefinition -Id $_.Id -Force | Out-Null
    }
}

Write-Host "Moving subscription back to the Tenant Root Group"
New-AzManagementGroupSubscription -GroupName $TenantId -SubscriptionId $SubscriptionId

foreach ($mg in 'mg-landgate-sim', 'mg-epac-dev') {
    if (Get-AzManagementGroup -GroupName $mg -ErrorAction SilentlyContinue) {
        Write-Host "Removing management group $mg"
        Remove-AzManagementGroup -GroupName $mg | Out-Null
    }
}
