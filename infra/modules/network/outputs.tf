output "vpc_id" {
  description = "ID of the isolated AIRKit VPC"
  value       = aws_vpc.airkit_vpc.id
}

output "private_subnet_id" {
  description = "ID of the zero-egress private subnet"
  value       = aws_subnet.airkit_private_subnet.id
}

output "security_group_id" {
  description = "ID of the zero-egress security group"
  value       = aws_security_group.airkit_sg.id
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 Gateway Endpoint (only route out of the subnet)"
  value       = aws_vpc_endpoint.s3_gateway.id
}
