
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

variable "image_uri" {
  description = "Container image URI (e.g. public.ecr.aws/<alias>/phpmyadmin-lambda-adapter:latest)"
}

variable "basic_auth_user" {
  description = "Basic auth user name"
  default     = "admin"
}

variable "basic_auth_password" {
  description = "Basic auth password"
  sensitive   = true
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
}
