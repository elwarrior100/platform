# Secrets vault (OCI Vault) read by the External Secrets Operator. See modbus_data_plataform docs/adr/011.
#
# What lives here: the compartment, the vault, the master key and WHO may read secrets.
# What does NOT live here: secret values. Creating them with Terraform would store them in plain text in
# terraform.tfstate, so they are created by scripts/vault-seed.sh with the OCI CLI instead.
#
# Cost: a DEFAULT vault with software-protected keys is part of Always Free (150 secrets per tenancy).
# A VIRTUAL_PRIVATE vault is billed, so the vault type is fixed below.

resource "oci_identity_compartment" "secrets" {
  compartment_id = var.compartment_id
  name           = "platform-secrets"
  description    = "Vault and secrets for the data platform (read by the External Secrets Operator)"
  enable_delete  = false # a terraform destroy must not delete the compartment that holds the secrets
}

resource "oci_kms_vault" "platform" {
  compartment_id = oci_identity_compartment.secrets.id
  display_name   = "platform"
  vault_type     = "DEFAULT" # NOT "VIRTUAL_PRIVATE": that one is billed
}

resource "oci_kms_key" "platform" {
  compartment_id      = oci_identity_compartment.secrets.id
  display_name        = "platform-master-key"
  management_endpoint = oci_kms_vault.platform.management_endpoint
  protection_mode     = "SOFTWARE" # free; HSM keys only have 20 free key versions

  key_shape {
    algorithm = "AES"
    length    = 32
  }
}

# --- Who may read secrets -------------------------------------------------------------------------------
# Read-only, and only secrets in this compartment. Never the administrator key in ~/.oci.

# Local cluster (Mac): a dedicated user with an API key. The private key stays in ~/.oci/eso-reader/ and is
# copied into the cluster by a script; only the PUBLIC key is given to Oracle here.
resource "oci_identity_group" "eso_readers" {
  compartment_id = var.compartment_id
  name           = "eso-readers"
  description    = "Read-only access to the platform secrets (External Secrets Operator)"
}

resource "oci_identity_user" "eso_reader" {
  compartment_id = var.compartment_id
  name           = "eso-reader"
  description    = "External Secrets Operator in the local cluster: reads platform secrets, nothing else"
  email          = var.eso_reader_email # Identity Domains require a primary email
}

resource "oci_identity_user_group_membership" "eso_reader" {
  group_id = oci_identity_group.eso_readers.id
  user_id  = oci_identity_user.eso_reader.id
}

resource "oci_identity_api_key" "eso_reader" {
  user_id   = oci_identity_user.eso_reader.id
  key_value = file(pathexpand(var.eso_reader_public_key_path))
}

# Oracle cluster: the VM itself is authorised (instance principal), so no key is stored in that cluster.
resource "oci_identity_dynamic_group" "platform_instances" {
  compartment_id = var.compartment_id
  name           = "platform-instances"
  description    = "The platform VM, so its External Secrets Operator can read secrets without a key"
  matching_rule  = "instance.id = '${oci_core_instance.platform.id}'"
}

resource "oci_identity_policy" "read_secrets" {
  compartment_id = var.compartment_id
  name           = "platform-read-secrets"
  description    = "Read-only access to the secrets in platform-secrets"
  statements = [
    "Allow group ${oci_identity_group.eso_readers.name} to read secret-bundles in compartment ${oci_identity_compartment.secrets.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.platform_instances.name} to read secret-bundles in compartment ${oci_identity_compartment.secrets.name}",
  ]
}

output "vault_ocid" {
  value = oci_kms_vault.platform.id
}

output "master_key_ocid" {
  value = oci_kms_key.platform.id
}

output "secrets_compartment_ocid" {
  value = oci_identity_compartment.secrets.id
}

output "eso_reader" {
  description = "What the local External Secrets Operator needs (the private key stays in ~/.oci/eso-reader/)"
  value = {
    user_ocid   = oci_identity_user.eso_reader.id
    fingerprint = oci_identity_api_key.eso_reader.fingerprint
  }
}
