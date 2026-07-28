# Provisions the KMS key used to encrypt OpenTofu state at rest.
#
# NOTE: this module has a bootstrapping problem worth being explicit about.
# OpenTofu's state encryption block (in main.tf) needs a KMS key ARN before
# it can encrypt the very state file that would record this key's creation.
# The install script (see install/lib/preflight.sh) handles this by running
# a small, separate `tofu apply` against just this module first — with an
# UNENCRYPTED local state file, since nothing sensitive exists yet — to
# create the key, then feeding its ARN into the main apply as -var
# kms_key_arn=... where state encryption is already configured.
#
# Do not fold this module into the main root module's default state; it
# must remain independently applicable for that two-phase bootstrap to work.

variable "aws_region" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_kms_key" "airkit_state_key" {
  description             = "Encrypts AIRKit OpenTofu state (subnet IDs, instance IPs, volume IDs)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(var.tags, { Name = "airkit-state-encryption-key" })
}

resource "aws_kms_alias" "airkit_state_key_alias" {
  name          = "alias/airkit-state-key"
  target_key_id = aws_kms_key.airkit_state_key.key_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key to pass as -var kms_key_arn=... to the main apply"
  value       = aws_kms_key.airkit_state_key.arn
}
