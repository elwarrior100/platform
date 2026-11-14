terraform {
  required_version = ">= 1.5"
  # Remote state in the versioned platform-tfstate bucket (backups.tf), so it no longer lives only on one laptop.
  # The bucket/namespace/region come from backend.hcl (not in git): terraform init -backend-config=backend.hcl
  backend "oci" {}

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.13"
    }
  }
}

provider "oci" {
  config_file_profile = "DEFAULT" # usa ~/.oci/config
}
