resource "aws_iam_role" "lambda" {
  name               = "${var.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Attach VPC access policy when the Lambda is deployed inside a VPC.
# AWSLambdaVPCAccessExecutionRole grants permissions to create and manage
# ENIs so that the function can reach resources within the VPC.
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  count      = length(var.subnet_ids) > 0 ? 1 : 0
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "phpmyadmin" {
  function_name = var.name
  package_type  = "Image"
  image_uri     = var.image_uri
  role          = aws_iam_role.lambda.arn

  # phpMyAdmin can be slow to initialize; allow enough time per request
  timeout     = 30
  memory_size = 512

  environment {
    variables = {
      PMA_ARBITRARY       = var.pma_arbitrary
      BACIC_AUTH_USER     = var.basic_auth_user
      BACIC_AUTH_PASSWORD = var.basic_auth_password
      PMA_SSL             = var.pma_ssl
    }
  }

  # To place the Lambda function inside a VPC, set subnet_ids and
  # security_group_ids.  Leave them empty (the default) to deploy
  # the function without VPC attachment.
  dynamic "vpc_config" {
    for_each = length(var.subnet_ids) > 0 ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }
}

resource "aws_lambda_function_url" "phpmyadmin" {
  function_name      = aws_lambda_function.phpmyadmin.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["*"]
    allow_methods = ["*"]
    allow_headers = ["*"]
    max_age       = 0
  }
}

output "lambda_function_url" {
  description = "Lambda function URL (direct access)"
  value       = aws_lambda_function_url.phpmyadmin.function_url
}
