# Backups (Always Free): Object Storage for database dumps and the Terraform state, and a weekly backup of the
# VM's boot volume. Everything here is free: 20 GB of Object Storage and 5 volume backups per tenancy.

data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.compartment_id
}

locals {
  home_region = [for r in data.oci_identity_region_subscriptions.this.region_subscriptions : r.region_name if r.is_home_region][0]
}

resource "oci_identity_compartment" "backups" {
  compartment_id = var.compartment_id
  name           = "platform-backups"
  description    = "Database dumps and the Terraform state of the data platform"
  enable_delete  = false
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_id
}

# Nightly pg_dump files, written by the pg-backup CronJob running on the VM (instance principal).
resource "oci_objectstorage_bucket" "backups" {
  compartment_id = oci_identity_compartment.backups.id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "platform-backups"
  access_type    = "NoPublicAccess"
  versioning     = "Disabled"
}

# Oracle deletes dumps older than 14 days, so the bucket never grows past the free 20 GB.
resource "oci_objectstorage_object_lifecycle_policy" "backups" {
  namespace = data.oci_objectstorage_namespace.this.namespace
  bucket    = oci_objectstorage_bucket.backups.name
  rules {
    name        = "delete-dumps-after-14-days"
    action      = "DELETE"
    is_enabled  = true
    time_amount = 14
    time_unit   = "DAYS"
    target      = "objects"
  }
  depends_on = [oci_identity_policy.backups]
}

# Remote Terraform state (backend "oci"), versioned so a bad apply can be rolled back.
resource "oci_objectstorage_bucket" "tfstate" {
  compartment_id = oci_identity_compartment.backups.id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "platform-tfstate"
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
}

# Copy of the lake objects (SeaweedFS bucket "lake": bronze, silver, lakeFS metadata ranges), synced nightly so a
# restore of the lakeFS database never points at objects that only lived on the VM disk. lakeFS objects never change,
# so the VM may create and read here but neither overwrite nor delete: a compromised VM cannot tamper with the copy.
resource "oci_objectstorage_bucket" "lake" {
  compartment_id = oci_identity_compartment.backups.id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "platform-lake-backup"
  access_type    = "NoPublicAccess"
  versioning     = "Disabled"
}

resource "oci_identity_policy" "backups" {
  compartment_id = var.compartment_id
  name           = "platform-backups"
  description    = "The VM can write and read dumps, but not delete them; Object Storage can expire old dumps"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.platform_instances.name} to read buckets in compartment ${oci_identity_compartment.backups.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.platform_instances.name} to manage objects in compartment ${oci_identity_compartment.backups.name} where all {target.bucket.name = '${oci_objectstorage_bucket.backups.name}', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_INSPECT', request.permission = 'OBJECT_READ'}}",
    "Allow dynamic-group ${oci_identity_dynamic_group.platform_instances.name} to manage objects in compartment ${oci_identity_compartment.backups.name} where all {target.bucket.name = '${oci_objectstorage_bucket.lake.name}', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_INSPECT', request.permission = 'OBJECT_READ'}}",
    "Allow service objectstorage-${local.home_region} to manage object-family in compartment ${oci_identity_compartment.backups.name}",
  ]
}

# Weekly incremental backup of the boot volume, kept for 3 weeks (at most ~4 backups: within the free 5).
resource "oci_core_volume_backup_policy" "weekly" {
  compartment_id = var.compartment_id
  display_name   = "platform-weekly"
  schedules {
    backup_type       = "INCREMENTAL"
    period            = "ONE_WEEK"
    day_of_week       = "SUNDAY"
    hour_of_day       = 4
    offset_type       = "STRUCTURED"
    retention_seconds = 3 * 7 * 24 * 3600
    time_zone         = "UTC"
  }
}

data "oci_core_boot_volume_attachments" "platform" {
  availability_domain = oci_core_instance.platform.availability_domain
  compartment_id      = var.compartment_id
  instance_id         = oci_core_instance.platform.id
}

resource "oci_core_volume_backup_policy_assignment" "boot" {
  asset_id  = data.oci_core_boot_volume_attachments.platform.boot_volume_attachments[0].boot_volume_id
  policy_id = oci_core_volume_backup_policy.weekly.id
}

output "backups_bucket" {
  value = "${data.oci_objectstorage_namespace.this.namespace}/${oci_objectstorage_bucket.backups.name}"
}

output "tfstate_bucket" {
  value = oci_objectstorage_bucket.tfstate.name
}
