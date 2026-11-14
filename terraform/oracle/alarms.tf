# Alarms that must work even when the whole VM is down, so they live in OCI Monitoring (outside the VM) and send email
# through OCI Notifications. All free: Always Free includes the Monitoring data points and 1000 email notifications
# a month. The in-cluster Prometheus/Grafana (platform/monitoring) covers everything inside the cluster.

resource "oci_ons_notification_topic" "alerts" {
  compartment_id = var.compartment_id
  name           = "platform-alerts"
  description    = "Alarms of the data platform"
}

# OCI emails a confirmation link to this address: the subscription only works after it is clicked.
resource "oci_ons_subscription" "email" {
  compartment_id = var.compartment_id
  topic_id       = oci_ons_notification_topic.alerts.id
  protocol       = "EMAIL"
  endpoint       = var.alert_email
}

locals {
  vm = "resourceId = \"${oci_core_instance.platform.id}\""
}

resource "oci_monitoring_alarm" "vm_down" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: VM not reporting (down?)"
  namespace                    = "oci_computeagent"
  query                        = "CpuUtilization[1m]{${local.vm}}.absent()"
  severity                     = "CRITICAL"
  pending_duration             = "PT10M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The platform VM sent no metrics for 10 minutes: it is probably down. Try ssh ubuntu@platform-oracle, else the OCI console."
  repeat_notification_duration = "PT4H"
}

resource "oci_monitoring_alarm" "cpu_high" {
  compartment_id        = var.compartment_id
  metric_compartment_id = var.compartment_id
  display_name          = "platform: CPU above 90% for 30 min"
  namespace             = "oci_computeagent"
  query                 = "CpuUtilization[5m]{${local.vm}}.mean() > 90"
  severity              = "WARNING"
  pending_duration      = "PT30M"
  is_enabled            = true
  destinations          = [oci_ons_notification_topic.alerts.id]
  body                  = "The platform VM has used more than 90% CPU for 30 minutes (2 OCPU). Check Grafana: Kubernetes / Compute Resources."
}

resource "oci_monitoring_alarm" "memory_high" {
  compartment_id        = var.compartment_id
  metric_compartment_id = var.compartment_id
  display_name          = "platform: memory above 92% for 15 min"
  namespace             = "oci_computeagent"
  query                 = "MemoryUtilization[5m]{${local.vm}}.mean() > 92"
  severity              = "CRITICAL"
  pending_duration      = "PT15M"
  is_enabled            = true
  destinations          = [oci_ons_notification_topic.alerts.id]
  body                  = "The platform VM has used more than 92% of its 12 GB for 15 minutes: pods may be evicted or OOM-killed."
}

# The nightly backup posts backup_success after a successful upload (envs/oracle/backup). No data point in a day
# means the backup did not run or failed: a dead man's switch for the backups.
resource "oci_monitoring_alarm" "backup_missing" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: no successful backup in 26 h"
  namespace                    = "platform_backup"
  query                        = "backup_success[1h].absent(26h)"
  severity                     = "CRITICAL"
  pending_duration             = "PT5M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The nightly database backup has not succeeded for 26 hours. Check: kubectl -n backup get jobs; logs of the latest pg-backup job."
  repeat_notification_duration = "PT12H"
}

resource "oci_identity_policy" "metrics" {
  compartment_id = var.compartment_id
  name           = "platform-post-metrics"
  description    = "The VM may post its own custom metrics (backup heartbeat), nothing else"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.platform_instances.name} to use metrics in tenancy where target.metrics.namespace = 'platform_backup'",
  ]
}
