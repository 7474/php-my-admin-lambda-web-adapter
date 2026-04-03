
variable "access_key" {
  description = "AWS Access Key"
}

variable "secret_key" {
  description = "AWS Secret Key"
}

variable "region" {
  description = "AWS region for private ECR repository"
  default     = "ap-northeast-1"
}
