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

# "No heartbeat" alarms use <metric>[<window>].absent(): absent over the WHOLE window ([1d] = the last 24 h, [3h]).
# Not <metric>[1h].absent(26h): OCI evaluates that hour by hour, so it fired one hour after every heartbeat
# (2026-11-14/16: false alerts after each backup).
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
  display_name                 = "platform: no successful backup in 24 h"
  namespace                    = "platform_backup"
  query                        = "backup_success[1d].absent()"
  severity                     = "CRITICAL"
  pending_duration             = "PT1H"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The nightly database backup has not succeeded in the last 24 hours. Check: kubectl -n backup get jobs; logs of the latest pg-backup job."
  repeat_notification_duration = "PT12H"
}

resource "oci_identity_policy" "metrics" {
  compartment_id = var.compartment_id
  name           = "platform-post-metrics"
  description    = "The VM may post its own custom metrics (heartbeats, disk use), nothing else"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.platform_instances.name} to use metrics in tenancy where any {target.metrics.namespace = 'platform_backup', target.metrics.namespace = 'platform_pipeline', target.metrics.namespace = 'platform_node'}",
  ]
}

# The hourly silver must keep up: a job in the backup namespace checks the newest silver commit in lakeFS every 30 min
# and posts silver_fresh while it is less than 3 h old (envs/oracle/ops/silver-freshness.yaml). No data point for
# 3 h means the pipeline stalled (or the check itself stopped).
resource "oci_monitoring_alarm" "silver_stale" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: silver not updated for 3 h"
  namespace                    = "platform_pipeline"
  query                        = "silver_fresh[3h].absent()"
  severity                     = "WARNING"
  pending_duration             = "PT5M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "No silver hour merged into lakeFS main for 3 hours. Check Airflow (silver_hourly runs) and the writer."
  repeat_notification_duration = "PT6H"
}

# The nightly lake copy posts lake_sync_success when it finishes (envs/oracle/backup/lake-sync.yaml).
resource "oci_monitoring_alarm" "lake_sync_missing" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: no successful lake copy in 24 h"
  namespace                    = "platform_backup"
  query                        = "lake_sync_success[1d].absent()"
  severity                     = "CRITICAL"
  pending_duration             = "PT1H"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The nightly copy of the lake objects has not succeeded in the last 24 hours. Check: kubectl -n backup get jobs; logs of the latest lake-sync job."
  repeat_notification_duration = "PT12H"
}

# The drill also posts lake_drill_success = 0 when its check fails: that alarms at once, not after two days.
resource "oci_monitoring_alarm" "lake_drill_failed" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: lake restore drill FAILED"
  namespace                    = "platform_backup"
  query                        = "lake_drill_success[1h].min() < 1"
  severity                     = "CRITICAL"
  pending_duration             = "PT1M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The lake restore drill ran and found objects missing or changed in the backup. Read: kubectl -n ops logs job/<latest lake-restore-drill job> -c check"
  repeat_notification_duration = "PT24H"
}

# The daily lake restore drill posts lake_drill_success every run that reaches its check (envs/oracle/ops/lake-restore-drill.yaml):
# nothing for 2 days means it did not even get that far.
resource "oci_monitoring_alarm" "lake_drill_missing" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: lake restore drill not run in 24 h"
  namespace                    = "platform_backup"
  query                        = "lake_drill_success[1d].absent()"
  severity                     = "WARNING"
  pending_duration             = "PT1H"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The daily lake restore drill (ops/lake-restore-drill, 04:15 UTC) has not posted a result in the last 24 hours. Run ./scripts/lake-restore-test.sh and read its output."
  repeat_notification_duration = "PT24H"
}

# lakeFS GC heartbeat (envs/oracle/ops/gc-freshness.yaml, daily): 0 = no successful GC in 8 days; nothing = the check
# itself did not run. Without GC the lake grows until storage_high fires, weeks later.
resource "oci_monitoring_alarm" "lake_gc_failed" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: lakeFS GC has not succeeded in 8 days"
  namespace                    = "platform_backup"
  query                        = "lake_gc_success[1h].min() < 1"
  severity                     = "WARNING"
  pending_duration             = "PT1M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "No lakefs-gc Job succeeded in the last 8 days. Check: kubectl -n data get jobs; logs of the latest lakefs-gc job."
  repeat_notification_duration = "PT24H"
}

resource "oci_monitoring_alarm" "lake_gc_check_missing" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: lakeFS GC check not running"
  namespace                    = "platform_backup"
  query                        = "lake_gc_success[1d].absent()"
  severity                     = "WARNING"
  pending_duration             = "PT1H"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The daily GC check (ops/gc-freshness) posted nothing in the last 24 hours. Check: kubectl -n ops get jobs."
  repeat_notification_duration = "PT24H"
}

# VM disk (envs/oracle/ops/node-health.yaml posts it every 30 min; OCI does not measure an instance's filesystem).
resource "oci_monitoring_alarm" "disk_high" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: VM disk above 80%"
  namespace                    = "platform_node"
  query                        = "node_disk_used_pct[30m].max() > 80"
  severity                     = "WARNING"
  pending_duration             = "PT5M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The VM disk is over 80% (kubelet evicts pods at 95%). Check: df -h /; sudo du -sh /var/lib/rancher/k3s/*; old images: sudo k3s crictl rmi --prune."
  repeat_notification_duration = "PT24H"
}

resource "oci_monitoring_alarm" "disk_check_missing" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: VM disk check not running"
  namespace                    = "platform_node"
  query                        = "node_disk_used_pct[3h].absent()"
  severity                     = "WARNING"
  pending_duration             = "PT5M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The disk check (ops/node-health) posted nothing for 3 hours. Check: kubectl -n ops get jobs."
  repeat_notification_duration = "PT24H"
}

# Always Free includes 50,000 Object Storage requests a month; beyond that each 10k costs money. The lake copy once
# needed ~17k a day (ADR-016): warn when a day goes over 1,500 (a 45k/month pace), before anything is charged.
resource "oci_monitoring_alarm" "objectstorage_requests_high" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = oci_identity_compartment.backups.id
  display_name                 = "platform: Object Storage requests above the free pace"
  namespace                    = "oci_objectstorage"
  query                        = "AllRequests[1d].grouping().sum() > 1500"
  severity                     = "WARNING"
  pending_duration             = "PT5M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "More than 1,500 Object Storage requests in a day (Always Free: 50,000 a month). Check what ran: kubectl -n backup get jobs; kubectl -n ops get jobs; the lake copy should be ~4 requests a night (ADR-016)."
  repeat_notification_duration = "PT24H"
}

# Always Free gives 20 GB of Object Storage in total; warn well before the dumps and the lake copy reach it.
resource "oci_monitoring_alarm" "storage_high" {
  for_each              = { lake = { bucket = oci_objectstorage_bucket.lake.name, gb = 12 }, dumps = { bucket = oci_objectstorage_bucket.backups.name, gb = 5 } }
  compartment_id        = var.compartment_id
  metric_compartment_id = oci_identity_compartment.backups.id
  display_name          = "platform: bucket ${each.value.bucket} above ${each.value.gb} GB"
  namespace             = "oci_objectstorage"
  query                 = "StoredBytes[1h]{resourceDisplayName = \"${each.value.bucket}\"}.max() > ${each.value.gb * 1000000000}"
  severity              = "WARNING"
  pending_duration      = "PT1H"
  is_enabled            = true
  destinations          = [oci_ons_notification_topic.alerts.id]
  body                  = "Object Storage bucket ${each.value.bucket} is above ${each.value.gb} GB. Always Free includes 20 GB in total."
}
