variable "compartment_id" {
  description = "OCID do tenancy (root compartment)"
  type        = string
}

variable "subnet_id" {
  description = "OCID da subnet PÚBLICA"
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

# Os valores por omissão seguem o perfil core+gov do plano (docs/PLAN.md §9, ~16 GB) e cabem no Always Free
# (limite atual da conta: 2 OCPU e 12 GB de RAM no total, somando TODAS as instâncias A1). Se já tens outra VM A1, baixa isto.
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
