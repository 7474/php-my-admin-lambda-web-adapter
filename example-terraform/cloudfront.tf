resource "aws_cloudfront_cache_policy" "phpmyadmin_use_origin_cache_default_ttl_long" {
  name        = "${var.name}-cache-optimized-default-ttl-long"
  comment     = "Cache optimized behavior with default TTL set to 1 day"
  default_ttl = 86400
  max_ttl     = 31536000
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }

    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

data "aws_cloudfront_origin_request_policy" "managed_all_viewer_except_host_header" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "phpmyadmin" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = var.name

  origin {
    domain_name = trimsuffix(trimprefix(aws_lambda_function_url.phpmyadmin.function_url, "https://"), "/")
    origin_id   = "lambda"

    # Secret header that Lambda/Apache uses to reject requests that bypass
    # CloudFront and arrive at the Function URL directly.
    custom_header {
      name  = "X-Origin-Verify"
      value = var.cloudfront_origin_secret
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "lambda"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.phpmyadmin_use_origin_cache_default_ttl_long.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.managed_all_viewer_except_host_header.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = "https://${aws_cloudfront_distribution.phpmyadmin.domain_name}"
}
