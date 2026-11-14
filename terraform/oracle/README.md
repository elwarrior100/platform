# Terraform: Oracle VM (Always Free, Ampere A1)

Manages the VM where the platform runs (k3s and the rest), its firewall, the secrets vault and the backups.

⚠️ **Before the first `apply`:** create a budget / cost alert in the OCI console (Billing → Budgets) and check the
Always Free ceiling of your account (Governance → Limits).

Prerequisites: `~/.oci/config` with the `DEFAULT` profile and an SSH key at `~/.ssh/id_ed25519.pub`.

```bash
cd terraform/oracle
cp terraform.tfvars.example terraform.tfvars   # fill in the OCIDs (this file is not committed)
cp backend.hcl.example backend.hcl             # set the Object Storage namespace: oci os ns get (not committed)
terraform init -backend-config=backend.hcl     # state lives in the versioned platform-tfstate bucket
terraform plan
terraform apply
```

**Adopting a VM created in the console:** set `instance_ocid` in `terraform.tfvars`. The `import` block in
`imports.tf` then brings the existing instance into the state instead of creating a second one. Match
`instance_name` and `boot_volume_size_in_gbs` to the real VM so the plan shows
`1 to import, 0 to add, 0 to change, 0 to destroy` before applying.

**Out of host capacity:** Terraform fails immediately and does not retry. To keep trying:

```bash
until terraform apply -auto-approve; do echo "No capacity. Retrying in 5 minutes."; sleep 300; done
```

If the VM already exists, `apply` has nothing to do and the loop ends, so it never creates duplicates.

**Notes**
- The state is remote (bucket `platform-tfstate`, versioned, created by `backups.tf`); it contains sensitive data and
  never goes to git. A bad apply can be rolled back by restoring an older object version.
- Always Free A1 gives **2 OCPU / 12 GB RAM / 200 GB disk in total** across all A1 instances of the account
  (it was 4 / 24 before 2026). The defaults use all of it.
- `ignore_changes` on the image stops a newer Ubuntu release from recreating the VM.
- Pin the provider version after checking registry.terraform.io (currently `>= 5.0`).
