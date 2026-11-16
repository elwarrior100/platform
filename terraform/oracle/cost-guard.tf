# Cost kill-switch (ADR-017; envs/oracle/ops/cost-guard.yaml). Every hour a job on the VM reads the month's spend from
# the budget; at EUR 1.00 it zeroes the tenancy quotas and soft-stops the VM. It never deletes anything. These are the
# least permissions it needs (the same set Oracle's own "Zero Quota Policy Creator" function uses, minus compartments):
#   - read the budgets (the spend)
#   - create a quota and look quotas up; NOT update or delete them: a compromised VM cannot lift a quota a person set
#   - power actions on instances in the root compartment, where this VM is the only instance
resource "oci_identity_policy" "cost_guard" {
  compartment_id = var.compartment_id
  name           = "platform-cost-guard"
  description    = "The VM's cost kill-switch: read the budget, create a zero quota, stop itself. Never delete."
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.platform_instances.name} to read usage-budgets in tenancy",
    "Allow dynamic-group ${oci_identity_dynamic_group.platform_instances.name} to manage quota in tenancy where any {request.permission = 'QUOTA_CREATE', request.permission = 'QUOTA_INSPECT', request.permission = 'QUOTA_READ'}",
    "Allow dynamic-group ${oci_identity_dynamic_group.platform_instances.name} to use instances in tenancy where request.permission = 'INSTANCE_POWER_ACTIONS'",
  ]
}

# The guard tripped (or is about to): the month's spend reached the limit. The VM is then stopped on purpose.
resource "oci_monitoring_alarm" "cost_guard_tripped" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: COST LIMIT reached, VM being stopped"
  namespace                    = "platform_node"
  query                        = "cost_guard_spend[1h].max() >= 1"
  severity                     = "CRITICAL"
  pending_duration             = "PT1M"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The month's Oracle spend reached EUR 1.00: the cost guard zeroed the tenancy quotas (quota cost-guard-zero) and soft-stopped the VM. Nothing was deleted. Find the cause in Cost Analysis by service, then resume from the Mac: scripts/cost-guard-resume.sh (runbook: cost kill-switch)."
  repeat_notification_duration = "PT24H"
}

# A guard that stopped running protects nothing. (When the guard itself stops the VM this fires too, with vm_down.)
resource "oci_monitoring_alarm" "cost_guard_missing" {
  compartment_id               = var.compartment_id
  metric_compartment_id        = var.compartment_id
  display_name                 = "platform: cost guard not running"
  namespace                    = "platform_node"
  query                        = "cost_guard_spend[3h].absent()"
  severity                     = "WARNING"
  pending_duration             = "PT1H"
  is_enabled                   = true
  destinations                 = [oci_ons_notification_topic.alerts.id]
  body                         = "The cost guard (ops/cost-guard) posted no spend for 3 hours: the kill-switch is not watching. Check: kubectl -n ops get jobs; logs of the latest cost-guard job."
  repeat_notification_duration = "PT24H"
}
