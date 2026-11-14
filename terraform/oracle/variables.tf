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
