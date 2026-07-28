output "instance_id" {
  description = "Instance ID of the GPU inference node"
  value       = aws_instance.airkit_node.id
}

output "instance_private_ip" {
  description = "Private IP of the GPU inference node"
  value       = aws_instance.airkit_node.private_ip
}

output "model_weights_volume_id" {
  description = "EBS volume ID holding GLM-5.2 weights"
  value       = aws_ebs_volume.model_weights_vol.id
}
