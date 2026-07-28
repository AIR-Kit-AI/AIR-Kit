# Storage for GLM-5.2 weights. FP8 weights run roughly 1.5TB; io2 is used
# for guaranteed IOPS during KV-cache paging and initial weight hydration.
resource "aws_ebs_volume" "model_weights_vol" {
  availability_zone = "${var.aws_region}a"
  size              = var.model_weights_volume_size_gb
  type              = "io2"
  iops              = var.model_weights_volume_iops

  tags = merge(var.tags, { Name = "airkit-glm52-weights" })
}

# GPU compute node. Lives entirely inside the zero-egress private subnet;
# the only way it reaches anything outside the VPC is the S3 Gateway
# Endpoint wired up in the network module.
resource "aws_instance" "airkit_node" {
  ami                    = var.deep_learning_ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]

  # Explicitly no public IP. Belt-and-suspenders alongside the subnet's
  # missing IGW route and the security group's missing egress rules.
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/../../bootstrap.sh.tftpl", {
    weights_s3_bucket = var.weights_s3_bucket
    sglang_port       = var.sglang_port
  })

  root_block_device {
    volume_size = 500
    volume_type = "gp3"
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  tags = merge(var.tags, { Name = "airkit-inference-node" })
}

resource "aws_volume_attachment" "ebs_att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.model_weights_vol.id
  instance_id = aws_instance.airkit_node.id
}
