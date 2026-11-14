# Firewall of the public subnet (the VCN's default security list, created in the console and adopted here).
#
# No inbound port is open to the internet: SSH and every web UI are reached through Tailscale, which only
# needs OUTBOUND traffic. If Tailscale ever fails on the VM, the OCI console's serial console still works
# (it does not use port 22). Kept from the console defaults: the ICMP rules that path-MTU discovery needs.
import {
  to = oci_core_security_list.public
  id = var.security_list_ocid
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "Default Security List for data-plataform"

  # removed on purpose: TCP 22 from 0.0.0.0/0 (SSH now goes through Tailscale: ssh ubuntu@platform-oracle)

  ingress_security_rules {
    description = "ICMP fragmentation-needed from anywhere (path MTU discovery)"
    protocol    = "1"
    source      = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    description = "ICMP destination-unreachable from inside the VCN"
    protocol    = "1"
    source      = "10.0.0.0/16"
    icmp_options {
      type = 3
    }
  }

  egress_security_rules {
    description = "All outbound traffic (apt, container images, OCI APIs, Tailscale)"
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}
