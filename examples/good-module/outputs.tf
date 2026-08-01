output "id" {
  description = "Bucket name, which is also the Terraform resource ID."
  value       = aws_s3_bucket.this.id
}

output "arn" {
  description = "Bucket ARN. Use this when composing IAM policy statements."
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name. Prefer this over the global one for CloudFront origins and same-region clients."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "sse_algorithm" {
  description = "Server-side encryption algorithm actually applied: AES256 or aws:kms."
  value       = local.sse_algorithm
}
