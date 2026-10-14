# Enterprise Policy as Code (EPAC) for Landgate

What EPAC is, what a hands-on proof of concept showed, and how we would adopt it in the Landgate
landing zone with Azure DevOps.

*Status: draft for scoping · EPAC module version tested: 11.5.9 · October 2026*

## Contents

1. [Summary](#summary)
2. [What EPAC is](#what-epac-is)
3. [Proof of concept results](#proof-of-concept-results)
4. [Adopting existing policy at Landgate](#adopting-existing-policy-at-landgate)
5. [Azure DevOps deployment](#azure-devops-deployment)
6. [Identities and permissions](#identities-and-permissions)
7. [Proposed phases](#proposed-phases)
8. [Decisions needed for scoping](#decisions-needed-for-scoping)

## Summary

- **EPAC** is Microsoft's open-source tool for managing Azure Policy from files in git, using a
  plan → review → deploy workflow.
- A **proof of concept** exported a hand-made policy assignment, tested it in a separate
  environment, and then took over the original. The original was not recreated, and nothing else
  was touched.
- At Landgate we would **export what exists first**, start in the safe `ownedOnly` mode, and run
  everything through **Azure DevOps pipelines** with an approval before each production deployment.
- The main open question is **who owns policy today**. If the landing zone's Terraform deploys
  policy, we must agree which tool manages what before EPAC takes anything over.

## What EPAC is

EPAC is a PowerShell module (`EnterprisePolicyAsCode`, published by Microsoft on the PowerShell
Gallery). It reads JSON files describing policy definitions, policy sets (initiatives),
assignments and exemptions. It compares them with what is in Azure and works out the changes needed.

It works much like `terraform plan` and `apply`, with one difference: there is no state file.
EPAC reads Azure directly on every run, and tags everything it deploys with a repository ID
(`pacOwnerId`), so it knows which resources it owns.

### The three commands

| Command | What it does | Changes Azure? |
|---|---|---|
| `Build-DeploymentPlans` | Compares the files with Azure and writes a plan listing new, update, replace and delete actions | No |
| `Deploy-PolicyPlan` | Applies the policy part of the plan, exactly as written | Yes |
| `Deploy-RolesPlan` | Creates the role assignments for policy managed identities (needed by DeployIfNotExists and Modify policies) | Yes |

A fourth command, `Export-AzPolicyResources`, is read-only. It turns existing policy in Azure into
EPAC files, and it's the starting point for adopting policy that already exists.

### Key terms

| Term | Meaning |
|---|---|
| PAC environment | A management group hierarchy EPAC deploys to, named by a `pacSelector`. The usual pair is `epac-dev` (test) and `tenant` (production). |
| deploymentRootScope | The top management group of an environment. Custom definitions are created there, and assignments go there or below. |
| Desired state: `ownedOnly` | EPAC changes and deletes only what it deployed. Everything else is left alone. This is the recommended start for an existing estate. |
| Desired state: `full` | EPAC also deletes any policy under the root that isn't in git. It's a later, deliberate step. |

### Repository layout

The repository holds only Landgate's configuration. The EPAC code is installed from the
PowerShell Gallery at a pinned version.

```
Definitions/
  global-settings.jsonc       environments, root scopes, desired state
  policyDefinitions/          custom policy definitions
  policySetDefinitions/       custom initiatives
  policyAssignments/          what is assigned where, with parameters
  policyExemptions/           per environment (CSV or JSON)
pipelines/                    Azure DevOps YAML from the EPAC starter kit
```

## Proof of concept results

The proof of concept ran as a stock EPAC deployment in a personal Azure tenant: module 11.5.9 on
PowerShell 7, with no custom scripts. Two empty management groups played the roles of the
Landgate hierarchy (`tenant`) and the test hierarchy (`epac-dev`). All policies used Audit
effects only.

| Step | What happened | Result |
|---|---|---|
| 1. Existing policy | A built-in policy was assigned by hand in the portal. This is the "before EPAC" state. | Done |
| 2. Export | `Export-AzPolicyResources` wrote it out as an assignment file and an ownership report. The report listed the owner as *unknown*. | Worked |
| 3. Test in epac-dev | The file was given an `epac-dev` scope and deployed as a new assignment. A second build showed no changes. | Worked |
| 4. Takeover in tenant | The plan showed a single `Update(owner,metadata)`. EPAC took ownership of the original without recreating it. | Worked |
| 5. New policy | A hand-written assignment file was deployed to both environments. The existing assignment was reported as unchanged. | Worked |

### Lessons learned

- **Read the takeover plan carefully.** For existing policy, the plan should show only
  `Update(owner,metadata)`. A `new` means EPAC didn't recognise the assignment, a `replace` means
  it would delete and recreate it, and a parameter change means the file differs from Azure.
  Stop and fix the file if you see any of these.
- **Never rename an exported assignment.** EPAC matches existing assignments by name and scope.
  Portal-created assignments have random names (for example `daa6e1abdf415f94b026e06d`), and
  changing one makes EPAC create a duplicate. Renaming is a separate, later clean-up.
- **Empty exemption files break the build in 11.5.9.** The export writes header-only
  `active-exemptions.csv` files, and these caused an error in an environment with no assignments.
  Delete the empty ones, but keep any that contain real exemptions.
- **PowerShell 7.4 or later is required.** Windows PowerShell 5.1 doesn't work, and modules
  installed there aren't visible to PowerShell 7.
- **The export skips Defender for Cloud auto-assignments** unless `-IncludeAutoAssigned` is used.
  Whether EPAC manages them is a decision to make.

## Adopting existing policy at Landgate

Landgate is an existing estate, so EPAC is introduced by exporting what exists, not by writing
policy from scratch.

1. **Discovery (read-only).** Run `Export-AzPolicyResources` against the production hierarchy.
   The output files and `policy-ownership.csv` show every custom definition, assignment and
   exemption, who created each one, and whether another tool (such as Terraform) already manages it.
2. **Agree the boundary.** Decide which policies EPAC will own. Anything still owned by another
   tool is left out of the repository, or excluded in `global-settings.jsonc`.
3. **Build epac-dev.** Create a separate management group hierarchy that mirrors the Landgate
   structure (platform, landing zones and so on) under its own root, not inside production. Add
   an `epac-dev` scope to the assignment files and deploy there first.
4. **Take over production.** Build the `tenant` plan and confirm it contains only
   `owner,metadata` updates, then deploy. From this point, changes go through git.
5. **Run in `ownedOnly` for several weeks.** Moving to `full` later is a separate decision, made
   after reviewing what it would delete.

## Azure DevOps deployment

EPAC ships ready-made Azure DevOps pipelines in its starter kit. We would generate them, not
write our own, so that upgrades and Microsoft's documentation stay relevant. They follow
*GitHub Flow*: work happens on `feature/*` branches, and `main` reflects production.

```powershell
# StarterKit folder comes from the EPAC GitHub repository
New-PipelinesFromStarterKit -StarterKitFolder .\StarterKit -PipelinesFolder .\pipelines `
  -PipelineType AzureDevOps -BranchingFlow GitHub -ScriptType module
```

```
epac-dev-pipeline.yml          runs on push to feature/*
  Plan epac-dev ──► Deploy epac-dev (environment PAC-DEV) ──► Plan tenant (preview)

epac-tenant-pipeline.yml       after merge to main
  Plan tenant ──► ⏸ Approval (environment PAC-POLICY) ──► Deploy policy ──► Deploy roles

epac-remediation-pipeline.yml  scheduled (daily by default)
  Remediate: starts remediation tasks for DeployIfNotExists and Modify policies
```

The deploy stage downloads the plan artifact from the plan stage. What the approver reviews is
therefore exactly what gets deployed: the plan isn't rebuilt between approval and deployment.
Deploy jobs are skipped automatically when the plan has no changes.

### Azure DevOps setup

| Item | Setup |
|---|---|
| Repository | A dedicated EPAC repository with `Definitions/` at the root. The generated pipelines expect this layout and need no path changes. |
| Environments | `PAC-DEV` without approvals. `PAC-POLICY` with an approval check from the platform team, which gates every production deployment. |
| Service connections | Azure Resource Manager connections using **workload identity federation**, so no secrets need storing or rotating. Names expected by the pipelines are listed in the next section. |
| Branch policy on `main` | Pull request with a required reviewer and a build validation run of the dev pipeline. |
| Module version | The starter-kit template installs the latest module. We would add `-RequiredVersion` so every run uses the same tested EPAC version, and upgrade deliberately. |
| Tenant pipeline trigger | The starter kit ships it as a manually triggered pipeline (`trigger: none`). We'd choose between a manual run after each merge and a trigger on `main`. The approval check applies either way. |

## Identities and permissions

EPAC recommends separate identities per job, so that the plan stage can only read and each
deploy stage can only do its own task. The service connection names below are the starter-kit
defaults.

| Service connection | Used for | Role | Scope |
|---|---|---|---|
| `sc-epac-plan` | Building plans for all environments | Reader | Tenant root group, or the intermediate root above both hierarchies |
| `sc-epac-dev` | Deploying to epac-dev | Resource Policy Contributor + Role Based Access Control Administrator | epac-dev root |
| `sc-epac-tenant-deploy` | Deploying policy to production | Resource Policy Contributor | Production root |
| `sc-epac-tenant-roles` | Role assignments for policy managed identities | Role Based Access Control Administrator (with a condition that blocks privileged roles) + `policyAssignments/read` | Production root |
| `sc-epac-tenant-remediation` | Scheduled remediation | Resource Policy Contributor | Production root |

> **Note:** Creating these app registrations and their federated credentials needs an Entra ID
> administrator. Granting the roles needs Owner or User Access Administrator at the management
> group roots. Both should be requested early, because they usually take the longest to arrange.

## Proposed phases

1. **Discovery.** Read-only export of production policy. Review the ownership report and agree
   the boundary with whoever owns the landing zone code.
2. **Foundation.** EPAC repository in Azure DevOps, epac-dev management group hierarchy,
   identities and service connections, and generated pipelines with the module version pinned.
3. **Takeover.** Exported files deployed to epac-dev, then production adopted through the tenant
   pipeline in `ownedOnly` mode. Each plan is reviewed for owner and metadata updates only.
4. **Business as usual.** All policy changes go through pull requests. Exemptions are managed in
   git. Remediation runs on a schedule, and EPAC is upgraded on a planned cycle.
5. **Full desired state (optional).** Once stable, assess switching to `full` so that anything
   not in git is removed. This is done only after reviewing exactly what it would delete.

## Decisions needed for scoping

| Question | Why it matters |
|---|---|
| Does the landing zone code (for example the ALZ Terraform modules) deploy policy today? | Two tools must not manage the same assignments. EPAC has an Azure Landing Zones integration if it is to take over the ALZ policy set. |
| What is the production management group root, and how will epac-dev mirror it? | Defines `deploymentRootScope` for both environments. epac-dev must be separate and must not be nested inside production. |
| Who approves production policy deployments? | Sets the approvers on the `PAC-POLICY` environment. |
| Should EPAC manage the Defender for Cloud assignments? | Sets `keepDfcSecurityAssignments` and whether the export includes them. |
| How are exemptions requested and approved today? | Exemptions move into git as files, so the request process should feed into pull requests. |
| Can pipelines use Microsoft-hosted agents, or are self-hosted agents required? | Affects network access and how the pipelines' `pool` is set. |
| Which Azure region should hold policy managed identities? | Sets `managedIdentityLocation`, likely `australiaeast` or `australiasoutheast`. |

## References

- [EPAC documentation](https://azure.github.io/enterprise-azure-policy-as-code/)
- [Azure DevOps pipelines](https://azure.github.io/enterprise-azure-policy-as-code/ci-cd-ado-pipelines/)
- [App registrations](https://azure.github.io/enterprise-azure-policy-as-code/ci-cd-app-registrations/)
- [Extracting existing policy](https://azure.github.io/enterprise-azure-policy-as-code/start-extracting-policy-resources/)
- [Starter kit pipelines](https://github.com/Azure/enterprise-azure-policy-as-code/tree/main/StarterKit/Pipelines/AzureDevOps)
