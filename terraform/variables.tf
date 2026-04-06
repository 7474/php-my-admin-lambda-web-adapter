variable "access_key" {
  description = "AWS Access Key"
}

variable "secret_key" {
  description = "AWS Secret Key"
}

variable "region" {
  default = "ap-northeast-1"
}

variable "name" {
  default = "phpmyadmin-lambda-adapter"
}

variable "pma_arbitrary" {
  description = "Allow connection to an arbitrary MySQL server (PMA_ARBITRARY=1)"
  default     = "1"
}

variable "pma_ssl" {
  description = "Enable SSL connection to MySQL server (e.g. for PlanetScale)"
  default     = ""
}

variable "subnet_ids" {
  description = "List of subnet IDs to place the Lambda function in (leave empty to deploy outside VPC)"
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "List of security group IDs to attach to the Lambda function when deployed in a VPC"
  type        = list(string)
  default     = []

  validation {
    condition     = (length(var.subnet_ids) == 0 && length(var.security_group_ids) == 0) || (length(var.subnet_ids) > 0 && length(var.security_group_ids) > 0)
    error_message = "subnet_ids and security_group_ids must either both be empty (no VPC) or both be non-empty (VPC deployment)."
  }
}

# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------

variable "cloudfront_origin_secret" {
  description = "Secret value that CloudFront adds as the X-Origin-Verify request header when forwarding to the Lambda origin. Apache rejects any request that omits or mismatches this value, preventing direct access to the Lambda Function URL that bypasses CloudFront. Must be at least 32 characters. Treat as sensitive; pass via -var or a .tfvars file excluded from version control."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.cloudfront_origin_secret) >= 32
    error_message = "cloudfront_origin_secret must be at least 32 characters long."
  }
}

variable "pma_blowfish_secret" {
  description = "Secret key used to encrypt phpMyAdmin cookie-based sessions (PMA_BLOWFISH_SECRET). Must be 32 characters or longer. Treat as sensitive; pass via -var or a .tfvars file excluded from version control."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.pma_blowfish_secret) >= 32
    error_message = "pma_blowfish_secret must be at least 32 characters long."
  }
}
