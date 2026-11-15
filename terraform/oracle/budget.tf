# Zero cost is a hard requirement. Budgets are free, but a compartment can have only one: the one created in the
# console ("Alertmax", EUR 1/month, its own rule at EUR 2) is imported here unchanged, and gets two more rules: any
# charge at all (one cent), or a forecast of more than five cents for the month, sends an email the same day.
# November 2026 already has EUR 0.012 from Object Storage requests (ADR-016), so "any-charge" fires once for it.
import {
  to = oci_budget_budget.zero_cost
  id = var.budget_ocid
}

resource "oci_budget_budget" "zero_cost" {
  compartment_id = var.compartment_id
  display_name   = "Alertmax"
  description    = "Atingiste o limite"
  amount         = 1
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.compartment_id]
}

resource "oci_budget_alert_rule" "any_charge" {
  budget_id      = oci_budget_budget.zero_cost.id
  display_name   = "any-charge"
  type           = "ACTUAL"
  threshold      = 0.01
  threshold_type = "ABSOLUTE"
  recipients     = var.alert_email
  message        = "The Oracle tenancy has been charged this month (zero-cost requirement). Check Cost Analysis by service; likely suspects: Object Storage requests (50k free/month), storage over 20 GB, a resource outside Always Free."
}

resource "oci_budget_alert_rule" "forecast_charge" {
  budget_id      = oci_budget_budget.zero_cost.id
  display_name   = "forecast-charge"
  type           = "FORECAST"
  threshold      = 0.05
  threshold_type = "ABSOLUTE"
  recipients     = var.alert_email
  message        = "Oracle forecasts a charge this month (zero-cost requirement). Check Cost Analysis by service before it happens."
}
