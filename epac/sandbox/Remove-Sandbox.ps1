<#
.SYNOPSIS
    SANDBOX ONLY. Removes everything New-SandboxBrownfield.ps1 and EPAC created.

.DESCRIPTION
    Deletes every policy assignment and custom policy/policy set definition at both sandbox
    management groups (including any that EPAC deployed), then deletes the two management groups.
    Touches nothing outside mg-landgate-sim and mg-epac-dev.
#>
[CmdletBinding()]
param()
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

foreach ($mg in 'mg-landgate-sim', 'mg-epac-dev') {
    if (Get-AzManagementGroup -GroupName $mg -ErrorAction SilentlyContinue) {
        Write-Host "Removing management group $mg"
        Remove-AzManagementGroup -GroupName $mg | Out-Null
    }
}
