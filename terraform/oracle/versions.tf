terraform {
  required_version = ">= 1.5"
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
