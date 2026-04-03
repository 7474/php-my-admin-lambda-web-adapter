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

  # Ensure IAM policy attachments are complete before the function is created
  # or updated; without this, AWS may reject the apply with an error such as
  # "execution role does not have permissions to call CreateNetworkInterface".
  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]

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

  # --- VPC placement ---
  # Lambda Function URL (and CloudFront in front of it) provides internet-facing
  # access to this function regardless of VPC placement.  Placing the function
  # inside a VPC only affects *outbound* network connectivity from the function:
  #
  #   Non-VPC (default)
  #     Internet → Function URL → Lambda → (no access to private VPC resources)
  #
  #   VPC placement (subnet_ids set)
  #     Internet → Function URL → Lambda → private RDS / Aurora in the same VPC  ✓
  #     Lambda → Internet (outbound)  ✗  blocked unless a NAT Gateway is present
  #
  # If the Lambda needs outbound internet access while inside a VPC (e.g. for
  # phpMyAdmin to reach an external host), attach a NAT Gateway to the VPC:
  #   1. Create a public subnet with an Internet Gateway route.
  #   2. Place a NAT Gateway in that public subnet.
  #   3. Add a default route (0.0.0.0/0 → NAT Gateway) to the private subnet
  #      route tables used by subnet_ids below.
  #
  # Leave subnet_ids empty (default) to keep the non-VPC deployment pattern.
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
  authorization_type = "AWS_IAM"
}

data "aws_caller_identity" "current" {}

# Allow CloudFront (signed by Origin Access Control) to invoke this Function URL.
resource "aws_lambda_permission" "allow_cloudfront_function_url" {
  statement_id           = "AllowCloudFrontFunctionUrlInvoke"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.phpmyadmin.function_name
  principal              = "cloudfront.amazonaws.com"
  function_url_auth_type = "AWS_IAM"
  source_arn             = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
}

# Some AWS clients additionally require lambda:InvokeFunction with
# invoked_via_function_url=true when using Function URL + AWS_IAM.
resource "aws_lambda_permission" "allow_cloudfront_invoke_function" {
  statement_id             = "AllowCloudFrontInvokeFunctionViaUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.phpmyadmin.function_name
  principal                = "cloudfront.amazonaws.com"
  source_arn               = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
  invoked_via_function_url = true
}

output "lambda_function_url" {
  description = "Lambda function URL (direct access)"
  value       = aws_lambda_function_url.phpmyadmin.function_url
}
