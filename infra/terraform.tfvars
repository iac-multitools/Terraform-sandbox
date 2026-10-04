# Non-secret settings, committed to git.
# admin_ssh_public_key and allowed_ssh_cidr come from GitHub repo variables in CI
# (TF_VAR_*), or from local.auto.tfvars when running locally.
resource_group_name = "terraform-sandbox" # region (australiaeast) comes from the RG itself
prefix              = "sandbox"
