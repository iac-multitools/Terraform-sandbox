# EPAC proof of concept

A plain, by-the-book [Enterprise Policy as Code (EPAC)](https://azure.github.io/enterprise-azure-policy-as-code/)
deployment, run in a personal Pay-As-You-Go subscription. It follows the same steps Landgate
will use: **export the existing policies first, then bring them under EPAC.**

Nothing here is customised. It uses the `EnterprisePolicyAsCode` PowerShell module, its standard
folder layout, and its standard commands. Only the `sandbox/` scripts are extra. They fake an
"existing estate" so the export step has something to export.

## What EPAC is

EPAC is a PowerShell module that manages Azure Policy from JSON files in git. It handles policy
definitions, policy set (initiative) definitions, assignments and exemptions.

```
 Definitions/  (JSON in git)                         Azure
 ┌─────────────────────────┐   Build-DeploymentPlans   ┌───────────────────────┐
 │ global-settings.jsonc   │ ───── compares ─────────► │ policy at the         │
 │ policyDefinitions/      │                           │ deploymentRootScope   │
 │ policySetDefinitions/   │   writes Output/plans     │ management group      │
 │ policyAssignments/      │                           │ and everything below  │
 │ policyExemptions/       │   Deploy-PolicyPlan ────► │                       │
 └─────────────────────────┘   Deploy-RolesPlan  ────► │ (MI role assignments) │
                                                       └───────────────────────┘
```

It works much like Terraform plan/apply, without a state file. EPAC reads Azure directly every
time, and tags everything it deploys with a `pacOwnerId` so it knows which resources belong to it.

| Term | Meaning |
|---|---|
| **PAC environment** (`pacSelector`) | A management group hierarchy EPAC deploys to, e.g. `epac-dev`, `tenant` |
| **deploymentRootScope** | Top management group of that environment. Custom definitions go here, and assignments go here or below |
| **pacOwnerId** | GUID identifying this repo. Resources carrying it are "owned" by EPAC |
| **desiredState.strategy** | `ownedOnly`: EPAC only touches what it owns. `full`: EPAC also **deletes** anything under the root that isn't in the repo |
| **Build → Deploy** | `Build-DeploymentPlans` writes a plan (no changes), then `Deploy-PolicyPlan` and `Deploy-RolesPlan` apply it |

## Where are the EPAC scripts?

They aren't in the repo, and that's on purpose. EPAC can be consumed in two ways:

| Approach | Repo contains | Scripts come from |
|---|---|---|
| **PowerShell module** (used here, recommended by EPAC) | `Definitions/` only, plus pipelines later | `Install-Module EnterprisePolicyAsCode` on your machine or the pipeline agent |
| Forked/copied source | `Definitions/` **and** a `Scripts/` folder copied from the EPAC GitHub repo | The repo itself |

With the module, the repo holds only *your* config (what policy you want). Microsoft's code
(how to deploy it) is installed from the PowerShell Gallery. Upgrading means changing the
version number, with no need to re-copy hundreds of scripts. The catch is to **pin the version**
(`-RequiredVersion`) both locally and in the pipeline, so everyone runs the same EPAC.

Scripts that do land in the repo later are the **CI/CD pipelines**. They come from EPAC's starter
kit (`New-PipelinesFromStarterKit ... -ScriptType module`), and each one just installs the module
and runs the same Build → Deploy commands as below.

## The sandbox layout

```
Tenant Root Group
├── mg-landgate-sim      pacSelector "tenant"    stands in for the Landgate hierarchy
│   └── Pay-As-You-Go subscription                 + hand-made "legacy" policies to export
└── mg-epac-dev          pacSelector "epac-dev"  empty test hierarchy, as EPAC recommends
```

Both environments use `ownedOnly`, which is EPAC's recommended starting point for an existing estate.

## Files

| Path | What it is |
|---|---|
| `Definitions/global-settings.jsonc` | The two PAC environments above |
| `Definitions/policy*/` | Policy files. Empty until the export step fills them |
| `Output/` | EPAC export and plan output. Regenerated each run (gitignored) |
| `sandbox/New-SandboxBrownfield.ps1` | **Sandbox only.** Creates the management groups and the "legacy" policies |
| `sandbox/Remove-Sandbox.ps1` | **Sandbox only.** Removes all of it again |

## Walkthrough

### 0. Prerequisites (once)

EPAC needs **PowerShell 7.4+**. Windows PowerShell 5.1 won't work. Run everything below in `pwsh`.

```powershell
winget install Microsoft.PowerShell                 # then open a new "pwsh" terminal
Install-Module Az -Scope CurrentUser
Install-Module EnterprisePolicyAsCode -Scope CurrentUser -RequiredVersion 11.5.9   # pin it; see "Where are the EPAC scripts?"
Connect-AzAccount -Tenant 1f5b14c6-0cbf-4012-931f-a1d26bcf0b3a
```

Permissions EPAC needs at the deploymentRootScope: **Resource Policy Contributor** and
**Role Based Access Control Administrator**. Whoever creates a management group gets Owner on it,
so step 1 covers this in the sandbox.

> If step 1 fails with `AuthorizationFailed` on management groups: in the portal go to
> **Microsoft Entra ID → Properties → Access management for Azure resources = Yes**, then sign out
> and back in (`Connect-AzAccount`) and re-run. This is a one-off for a personal tenant.

### 1. Create the fake existing estate (sandbox only)

```powershell
cd epac
.\sandbox\New-SandboxBrownfield.ps1
```

Check in the portal (**Policy → Assignments**, scope `mg-landgate-sim`) that the two `legacy-*`
assignments exist. Landgate already has this, so this step is skipped there.

### 2. Point EPAC at the folders

These are EPAC's own environment variables, so you don't pass folder paths to every command:

```powershell
$env:PAC_DEFINITIONS_FOLDER = ".\Definitions"
$env:PAC_OUTPUT_FOLDER      = ".\Output"
$env:PAC_INPUT_FOLDER       = ".\Output"
```

### 3. Export the existing policies

```powershell
Export-AzPolicyResources
```

This reads `global-settings.jsonc` and exports every custom definition, assignment and exemption
under each environment's root into `Output\export\Definitions\` (the script prints the exact path).
It also writes an ownership CSV showing who owns what today.

Review the output, then copy it into the real definitions folder:

```powershell
Copy-Item .\Output\export\Definitions\* .\Definitions\ -Recurse -Force
```

You should now have:
- `policyDefinitions\Tags\legacy-audit-rg-environment-tag.jsonc`
- one assignment file for the custom definition and one for *Allowed locations*

The exact names come from EPAC.

### 4. Add the dev scope to the assignments

The exported assignment files only have a `scope` for `tenant`, because that's where they were
found. To test them in `epac-dev` first, add a line to each file's `scope` block:

```jsonc
"scope": {
    "epac-dev": [ "/providers/Microsoft.Management/managementGroups/mg-epac-dev" ],
    "tenant":   [ "/providers/Microsoft.Management/managementGroups/mg-landgate-sim" ]
}
```

Custom definitions need no change. EPAC deploys them to every environment's root automatically.

### 5. Deploy to epac-dev

```powershell
Build-DeploymentPlans -PacEnvironmentSelector epac-dev   # read the summary: all "new"
Deploy-PolicyPlan     -PacEnvironmentSelector epac-dev
Deploy-RolesPlan      -PacEnvironmentSelector epac-dev   # nothing to do here: no DINE/Modify policies
```

Check that the definition and assignments appear at `mg-epac-dev`. Run `Build-DeploymentPlans`
again and it should report **no changes**, which proves the files and Azure now match.

### 6. Take over production (tenant)

```powershell
Build-DeploymentPlans -PacEnvironmentSelector tenant
```

**This is the plan to read carefully.** The resources already exist with the same names, so
expect *updates* (EPAC stamping its `pacOwnerId` metadata on them). You should see **no deletes and
no replacements**. If you see either, stop and find out why before deploying.

```powershell
Deploy-PolicyPlan -PacEnvironmentSelector tenant
Deploy-RolesPlan  -PacEnvironmentSelector tenant
```

From now on the files in git are the source of truth for these policies.

### 7. Make a change the EPAC way

Try one of these to watch the cycle work. Each time, edit a file, then Build → read the plan →
Deploy, first to `epac-dev`, then to `tenant`.
- Add `australiacentral` to the allowed locations parameter in the assignment file
- Change the custom definition's effect to `deny` (Terraform-sandbox RG needs an `Environment` tag first!)
- Delete an assignment file. Under `ownedOnly`, EPAC deletes it in Azure because EPAC owns it now

### 8. Clean up (sandbox only)

```powershell
.\sandbox\Remove-Sandbox.ps1
```

## Notes to carry into the Landgate scoping

- **Who owns policy today?** If the Landgate landing zone was built with the ALZ Terraform/Bicep
  modules, those modules already deploy the ALZ policies. EPAC and Terraform must not both manage
  the same assignments. Decide the split before step 6. EPAC has an
  [ALZ integration](https://azure.github.io/enterprise-azure-policy-as-code/integrating-with-alz-overview/)
  for taking them over.
- **Export is read-only and safe** to run against Landgate's production tenant at any time. It
  shows what exists and who owns it, which makes it a good first discovery task.
- **epac-dev management groups** need to mirror the Landgate structure (platform, landing zones, etc.)
  under their own separate root, not nested inside the production one.
- **Start with `ownedOnly`.** Moving to `full` (EPAC deletes anything not in git) is a later,
  deliberate decision, after a few weeks of running cleanly.
- **Defender for Cloud** auto-assigns policy at subscriptions. The export skips these by default,
  so decide whether EPAC should manage them (`keepDfcSecurityAssignments`).
- **DeployIfNotExists / Modify policies** need managed identities and role assignments. That's what
  `Deploy-RolesPlan` is for, and the deploying identity needs RBAC Administrator rights.
- **CI/CD** comes after this. EPAC ships starter pipelines for GitHub Actions and Azure DevOps
  (`New-PipelinesFromStarterKit`), using the same Build → approve → Deploy steps.
