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
