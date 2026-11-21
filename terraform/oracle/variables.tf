variable "compartment_id" {
  description = "Tenancy OCID (root compartment)"
  type        = string
}

variable "subnet_id" {
  description = "OCID of the PUBLIC subnet"
  type        = string
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "instance_name" {
  type    = string
  default = "modbus-platform"
}

# Defaults match the whole Always Free Ampere A1 quota (current account limit: 2 OCPU and 12 GB RAM
# in total, summed over ALL A1 instances). Lower them if another A1 VM exists.
variable "ocpus" {
  type    = number
  default = 2
}

variable "memory_in_gbs" {
  type    = number
  default = 12
}

# Always Free: 200 GB of boot + block volume storage in total (limit total-free-storage-gb of the tenancy).
variable "boot_volume_size_in_gbs" {
  type    = number
  default = 100
}

variable "instance_ocid" {
  description = "OCID of the existing instance (created in the console) that imports.tf adopts"
  type        = string
}

variable "eso_reader_public_key_path" {
  description = "PUBLIC key of the eso-reader API key (the private key never leaves ~/.oci/eso-reader/)"
  type        = string
  default     = "~/.oci/eso-reader/key_public.pem"
}

variable "eso_reader_email" {
  description = "Primary email for the eso-reader user (Identity Domains require one). Set in terraform.tfvars, not in git"
  type        = string
}

variable "vcn_id" {
  description = "OCID of the VCN created in the console (data-plataform)"
  type        = string
}

variable "security_list_ocid" {
  description = "OCID of the security list of the public subnet, adopted by network.tf"
  type        = string
}

variable "alert_email" {
  description = "Where OCI alarms are emailed (set in terraform.tfvars, not in git)"
  type        = string
}

variable "budget_ocid" {
  description = "The tenancy's existing budget (created in the console as \"Alertmax\"; one budget per compartment), imported in budget.tf"
  type        = string
}

# The modbus project on Oracle (collector, writer, silver). false while it is paused on purpose: the silver alarms are
# switched off, since no silver is expected (the platform's own alarms stay on).
variable "modbus_running" {
  type    = bool
  default = true # set false to pause the project on purpose (with the projects ApplicationSet patch, docs/PLAN.md)
}
