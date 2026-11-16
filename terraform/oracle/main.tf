data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "platform" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  display_name        = var.instance_name
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_arm.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = true
    # pinned: the ops/gc-freshness network policy allows the Kubernetes API at exactly this address
    private_ip = "10.0.0.43"
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
  }

  lifecycle {
    # a newer Ubuntu image must not force the VM to be recreated (and its data lost)
    # cost-guard-ack is set by scripts/cost-guard-resume.sh (ADR-017), not by Terraform
    ignore_changes = [source_details[0].source_id, freeform_tags["cost-guard-ack"]]
  }
}

output "public_ip" {
  value = oci_core_instance.platform.public_ip
}

output "ssh" {
  value = "ssh ubuntu@${oci_core_instance.platform.public_ip}"
}
