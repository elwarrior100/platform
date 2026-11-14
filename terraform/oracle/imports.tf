# Adopt the instance that was created in the console instead of creating a second one (the Always Free A1 quota,
# 2 OCPU / 12 GB, only fits one). Its OCID comes from terraform.tfvars (not in git).
# After the first successful apply the instance is in the state and this block can be removed.
import {
  to = oci_core_instance.platform
  id = var.instance_ocid
}
