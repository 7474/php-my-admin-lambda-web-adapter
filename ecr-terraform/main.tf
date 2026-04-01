locals {
  name = "phpmyadmin-lambda-adapter"
}

provider "aws" {
  # ECR Public is only available in us-east-1
  region     = "us-east-1"
  access_key = var.access_key
  secret_key = var.secret_key

  default_tags {
    tags = {
      Environment = local.name
    }
  }
}

module "public_ecr" {
  source = "terraform-aws-modules/ecr/aws"

  repository_name = local.name
  repository_type = "public"

  public_repository_catalog_data = {
    description       = "Docker container for phpMyAdmin running on AWS Lambda via Lambda Web Adapter."
    about_text        = "See. https://github.com/7474/php-my-admin-lambda-web-adapter"
    usage_text        = "See. https://github.com/7474/php-my-admin-lambda-web-adapter"
    operating_systems = ["Linux"]
    architectures     = ["x86"]
  }
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:7474/php-my-admin-lambda-web-adapter:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions.json
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr_push" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_ecr_push.arn
}

resource "aws_iam_policy" "github_actions_ecr_push" {
  name   = "${local.name}-github-actions"
  policy = data.aws_iam_policy_document.github_actions_ecr_push.json
}

data "aws_iam_policy_document" "github_actions_ecr_push" {
  statement {
    sid    = "AllowPushImage"
    effect = "Allow"
    actions = [
      "ecr-public:*"
    ]
    resources = [
      module.public_ecr.repository_arn
    ]
  }

  statement {
    sid    = "AllowLoginToECR"
    effect = "Allow"
    actions = [
      "ecr-public:GetAuthorizationToken",
      "sts:GetServiceBearerToken"
    ]
    resources = ["*"]
  }
}

output "repository_uri" {
  value = module.public_ecr.repository_uri
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
