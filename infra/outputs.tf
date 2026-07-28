output "vpc_id" {
  description = "ID of the isolated AIRKit VPC"
  value       = local.vpc_id
}

output "private_subnet_id" {
  description = "ID of the zero-egress private subnet"
  value       = local.private_subnet_id
}

output "instance_id" {
  description = "Instance ID of the GPU inference node"
  value       = local.instance_id
}

output "instance_private_ip" {
  description = "Private IP of the GPU inference node, reachable only from internal_corporate_cidr"
  value       = local.instance_private_ip
}

output "sglang_endpoint" {
  description = "Internal SGLang OpenAI-compatible API endpoint"
  value       = "http://${local.instance_private_ip}:${var.sglang_port}"
}

output "model_weights_volume_id" {
  description = "EBS volume ID holding GLM-5.2 weights"
  value       = local.model_weights_volume_id
}

output "security_group_id" {
  description = "Security group ID enforcing zero-egress / inbound-telemetry-only rules"
  value       = local.security_group_id
}
