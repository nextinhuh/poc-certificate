resource "aws_s3_bucket" "root_ca" {
  bucket        = "${var.project_name}-root-ca-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-root-ca"
  }
}

resource "aws_s3_bucket_public_access_block" "root_ca" {
  bucket                  = aws_s3_bucket.root_ca.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "current" {}

output "root_ca_bucket_name" {
  value       = aws_s3_bucket.root_ca.bucket
  description = "Passar como root_ca_bucket_name na 2a leva do poc-shared-infra (enable_mtls_listener = true)"
}
