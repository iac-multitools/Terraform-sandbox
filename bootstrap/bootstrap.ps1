<#
.SYNOPSIS
  One-time setup so GitHub Actions can run Terraform against a single, isolated resource group.

.DESCRIPTION
  Everything Terraform touches is confined to ONE resource group ("terraform-sandbox").
  The service principal has no rights anywhere else in the subscription.

  Creates (idempotently - safe to re-run):
    1. The "terraform-sandbox" resource group
    2. A storage account + container inside it to hold Terraform state,
       with a CanNotDelete lock so Terraform/the pipeline can't remove its own state
    3. An Entra ID app registration / service principal for GitHub Actions
    4. Federated credentials (OIDC) so GitHub can log in WITHOUT any stored secret:
         - pull requests                       -> used by the "plan" job
         - the "terraform-sandbox" environment -> used by the "apply" job
    5. Role assignments, all scoped to the resource group or below:
         - Contributor on the resource group (service principal)
         - Storage Blob Data Contributor on the state account (service principal + you)
    6. Registers the resource providers Terraform needs (the SPN can't, it isn't subscription-scoped)
    7. infra/backend.hcl pointing Terraform at the state storage
    8. GitHub repo variables + the "terraform-sandbox" environment (via the gh CLI)

  Prereqs: `az login` (as an Owner of the subscription) and `gh auth login`.

.EXAMPLE
  .\bootstrap\bootstrap.ps1
  .\bootstrap\bootstrap.ps1 -SshPublicKeyPath ~\.ssh\azure_sandbox.pub
#>
param(
    [string]$Location = "australiaeast",
    [string]$ResourceGroup = "terraform-sandbox",
    [string]$GitHubRepo = "iac-multitools/Terraform-sandbox",
    [string]$StateContainer = "tfstate",
    [string]$AppName = "github-terraform-sandbox",
    [string]$EnvironmentName = "terraform-sandbox",
    [string]$SshPublicKeyPath = "$HOME\.ssh\id_rsa.pub"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$backendFile = Join-Path $repoRoot "infra\backend.hcl"

# Resource providers used by infra/ (VM, networking, auto-shutdown schedule, state storage).
$resourceProviders = @("Microsoft.Compute", "Microsoft.Network", "Microsoft.Storage", "Microsoft.DevTestLab")

# az/gh are native exes: PowerShell won't stop on their failures, so check exit codes.
function Invoke-Native {
    $exe, $rest = $args
    $out = & $exe @rest
    if ($LASTEXITCODE -ne 0) { throw "Command failed: $exe $($rest -join ' ')" }
    return $out
}

Write-Host "==> Reading current Azure context" -ForegroundColor Cyan
$subscriptionId = Invoke-Native az account show --query id -o tsv
$subscriptionName = Invoke-Native az account show --query name -o tsv
$tenantId = Invoke-Native az account show --query tenantId -o tsv
$myObjectId = Invoke-Native az ad signed-in-user show --query id -o tsv
Write-Host "    Subscription: $subscriptionName ($subscriptionId)"
Write-Host "    Tenant:       $tenantId"

# ---------- 1. Resource group ----------
Write-Host "==> Ensuring resource group '$ResourceGroup' in $Location" -ForegroundColor Cyan
Invoke-Native az group create --name $ResourceGroup --location $Location --tags managed_by=bootstrap purpose=terraform-sandbox -o none
$rgId = Invoke-Native az group show --name $ResourceGroup --query id -o tsv

# ---------- 2. State storage ----------
Write-Host "==> Ensuring state storage" -ForegroundColor Cyan
# Reuse the storage account name from a previous run, otherwise generate a unique one.
$storageAccount = $null
if (Test-Path $backendFile) {
    $match = Select-String -Path $backendFile -Pattern 'storage_account_name\s*=\s*"([^"]+)"'
    if ($match) { $storageAccount = $match.Matches[0].Groups[1].Value }
}
if (-not $storageAccount) {
    $suffix = -join ((97..122) + (48..57) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
    $storageAccount = "sttfstate$suffix"
}
Write-Host "    Storage account: $storageAccount"

Invoke-Native az storage account create `
    --name $storageAccount --resource-group $ResourceGroup --location $Location `
    --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 `
    --allow-blob-public-access false -o none
# Versioning lets you recover an older state file if something goes wrong.
Invoke-Native az storage account blob-service-properties update `
    --account-name $storageAccount --resource-group $ResourceGroup --enable-versioning true -o none
Invoke-Native az storage container create `
    --name $StateContainer --account-name $storageAccount --auth-mode key -o none
$storageId = Invoke-Native az storage account show --name $storageAccount --resource-group $ResourceGroup --query id -o tsv

# The SPN is Contributor on the RG, which can't remove locks - so this protects the state
# file from the pipeline itself (e.g. a careless `terraform destroy`).
Invoke-Native az lock create --name "protect-terraform-state" --lock-type CanNotDelete `
    --resource-group $ResourceGroup --resource $storageAccount `
    --resource-type "Microsoft.Storage/storageAccounts" `
    --notes "Holds Terraform state. Remove manually when retiring the sandbox." -o none

# ---------- 3. App registration + service principal ----------
Write-Host "==> Ensuring app registration '$AppName'" -ForegroundColor Cyan
$appId = Invoke-Native az ad app list --display-name $AppName --query "[0].appId" -o tsv
if (-not $appId) {
    $appId = Invoke-Native az ad app create --display-name $AppName --query appId -o tsv
}
$spObjectId = Invoke-Native az ad sp list --spn $appId --query "[0].id" -o tsv
if (-not $spObjectId) {
    $spObjectId = Invoke-Native az ad sp create --id $appId --query id -o tsv
}
Write-Host "    Client ID: $appId"

# ---------- 4. Federated credentials (OIDC) ----------
Write-Host "==> Ensuring federated credentials" -ForegroundColor Cyan
$existingCreds = @(Invoke-Native az ad app federated-credential list --id $appId --query "[].name" -o tsv)
$creds = @(
    @{ name = "github-pull-request"; subject = "repo:${GitHubRepo}:pull_request" },
    @{ name = "github-env-$EnvironmentName"; subject = "repo:${GitHubRepo}:environment:$EnvironmentName" }
)
foreach ($c in $creds) {
    if ($existingCreds -contains $c.name) { Write-Host "    $($c.name) already exists"; continue }
    # Pass JSON via a file - inline JSON quoting to native exes is unreliable in Windows PowerShell.
    $tmp = New-TemporaryFile
    @{
        name      = $c.name
        issuer    = "https://token.actions.githubusercontent.com"
        subject   = $c.subject
        audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json | Set-Content -Path $tmp -Encoding ascii
    Invoke-Native az ad app federated-credential create --id $appId --parameters "@$tmp" -o none
    Remove-Item $tmp
    Write-Host "    Created $($c.name) -> $($c.subject)"
}

# ---------- 5. Role assignments (resource group scope only) ----------
function Set-RoleAssignment($principalId, $principalType, $role, $scope) {
    # (Avoid JMESPath functions like length(@) - parentheses get mangled by az.cmd in Windows PowerShell.)
    $existing = Invoke-Native az role assignment list --assignee $principalId --role $role --scope $scope --query "[].id" -o tsv
    if (-not $existing) {
        Invoke-Native az role assignment create --assignee-object-id $principalId `
            --assignee-principal-type $principalType --role $role --scope $scope -o none
        Write-Host "    Granted '$role' to $principalType"
    } else {
        Write-Host "    '$role' already granted to $principalType"
    }
}
Write-Host "==> Ensuring role assignments" -ForegroundColor Cyan
Set-RoleAssignment $spObjectId "ServicePrincipal" "Contributor" $rgId
Set-RoleAssignment $spObjectId "ServicePrincipal" "Storage Blob Data Contributor" $storageId
Set-RoleAssignment $myObjectId "User" "Storage Blob Data Contributor" $storageId

# ---------- 6. Resource providers ----------
Write-Host "==> Ensuring resource providers are registered" -ForegroundColor Cyan
foreach ($rp in $resourceProviders) {
    $state = Invoke-Native az provider show --namespace $rp --query registrationState -o tsv
    if ($state -ne "Registered") {
        Write-Host "    Registering $rp (can take a few minutes)..."
        Invoke-Native az provider register --namespace $rp --wait -o none
    }
    Write-Host "    $rp registered"
}

# ---------- 7. backend.hcl ----------
Write-Host "==> Writing infra/backend.hcl" -ForegroundColor Cyan
@"
resource_group_name  = "$ResourceGroup"
storage_account_name = "$storageAccount"
container_name       = "$StateContainer"
key                  = "sandbox.tfstate"
use_azuread_auth     = true
"@ | Set-Content -Path $backendFile -Encoding ascii

# ---------- 8. GitHub repo variables + environment ----------
Write-Host "==> Configuring GitHub repo $GitHubRepo" -ForegroundColor Cyan
Invoke-Native gh api --method PUT "repos/$GitHubRepo/environments/$EnvironmentName" --silent
Invoke-Native gh variable set AZURE_CLIENT_ID --repo $GitHubRepo --body $appId
Invoke-Native gh variable set AZURE_TENANT_ID --repo $GitHubRepo --body $tenantId
Invoke-Native gh variable set AZURE_SUBSCRIPTION_ID --repo $GitHubRepo --body $subscriptionId

if (Test-Path $SshPublicKeyPath) {
    $pubKey = (Get-Content $SshPublicKeyPath -Raw).Trim()
    Invoke-Native gh variable set ADMIN_SSH_PUBLIC_KEY --repo $GitHubRepo --body $pubKey
    Write-Host "    ADMIN_SSH_PUBLIC_KEY set from $SshPublicKeyPath"
} else {
    Write-Warning "No SSH public key at $SshPublicKeyPath. Create one with: ssh-keygen -t rsa -b 4096   then re-run this script."
}

$myIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
Invoke-Native gh variable set ALLOWED_SSH_CIDR --repo $GitHubRepo --body "$myIp/32"
Write-Host "    ALLOWED_SSH_CIDR set to $myIp/32"

Write-Host ""
Write-Host "Done. Commit infra/backend.hcl (it contains no secrets)." -ForegroundColor Green
Write-Host "For local plans run:  `$env:ARM_SUBSCRIPTION_ID = '$subscriptionId'"
