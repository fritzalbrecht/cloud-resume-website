#------------------------------------------------------------------------------
# Locals
#------------------------------------------------------------------------------
locals {
  website_bucket_name     = var.website_domain_name
  www_website_bucket_name = "www.${var.website_domain_name}"
}

#------------------------------------------------------------------------------
# S3 BUCKET - For access logs
#------------------------------------------------------------------------------
#tfsec:ignore:aws-s3-enable-versioning
module "s3_logs_bucket" {
  providers = {
    aws = aws.main
  }

  source  = "cn-terraform/logs-s3-bucket/aws"
  version = "1.0.6"
  # source  = "../terraform-aws-logs-s3-bucket"

  name_prefix                   = "${var.name_prefix}-log-bucket"
  aws_principals_identifiers    = formatlist("arn:aws:iam::%s:root", var.aws_accounts_with_read_view_log_bucket)
  block_s3_bucket_public_access = true
  s3_bucket_force_destroy       = var.log_bucket_force_destroy
  # enable_s3_bucket_server_side_encryption        = var.enable_s3_bucket_server_side_encryption
  # s3_bucket_server_side_encryption_sse_algorithm = var.s3_bucket_server_side_encryption_sse_algorithm
  # s3_bucket_server_side_encryption_key           = var.s3_bucket_server_side_encryption_key

  tags = merge({
    Name = "${var.name_prefix}-logs"
  }, var.tags)
}

#------------------------------------------------------------------------------
# Route53 Hosted Zone
#------------------------------------------------------------------------------
resource "aws_route53_zone" "hosted_zone" {
  provider = aws.main

  count = var.create_route53_hosted_zone ? 1 : 0

  name = var.website_domain_name
  tags = merge({
    Name = "${var.name_prefix}-hosted-zone"
  }, var.tags)
}

#------------------------------------------------------------------------------
# ACM Certificate
#------------------------------------------------------------------------------
resource "aws_acm_certificate" "cert" {
  provider = aws.acm_provider

  count = var.create_acm_certificate ? 1 : 0

  domain_name               = "*.${var.website_domain_name}"
  subject_alternative_names = [var.website_domain_name]

  validation_method = "DNS"

  tags = merge({
    Name = var.website_domain_name
  }, var.tags)

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_certificate_validation_records" {
  provider = aws.main

  for_each = var.create_acm_certificate ? {
    for dvo in aws_acm_certificate.cert[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 300
  type            = each.value.type
  zone_id         = var.create_route53_hosted_zone ? aws_route53_zone.hosted_zone[0].zone_id : var.route53_hosted_zone_id
}

resource "aws_acm_certificate_validation" "cert_validation" {
  provider = aws.acm_provider

  # Dependency to guarantee that certificate and DNS records are created before this resource
  depends_on = [
    aws_acm_certificate.cert,
    aws_route53_record.acm_certificate_validation_records,
  ]

  count = var.create_acm_certificate ? 1 : 0

  certificate_arn         = aws_acm_certificate.cert[0].arn
  validation_record_fqdns = [for record in aws_route53_record.acm_certificate_validation_records : record.fqdn]
}

#------------------------------------------------------------------------------
# Dynamodb Table
#------------------------------------------------------------------------------

resource "aws_dynamodb_table_item" "visitor-count" {
  table_name = aws_dynamodb_table.cloud-resume-visitor-count-table.name
  hash_key   = aws_dynamodb_table.cloud-resume-visitor-count-table.hash_key

  item = <<ITEM
{
  "ID": {"S": "Visitors"},
  "Count": {"N": "0"}
}
ITEM
}

resource "aws_dynamodb_table" "cloud-resume-visitor-count-table" {
  name           = "cloud-resume-visitor-count"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "ID"

  attribute {
    name = "ID"
    type = "S"
  }
}

#------------------------------------------------------------------------------
# Lambda Functions
#------------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "iam_for_cloud_resume_lambdas" {
  name               = "iam_for_cloud_resume_lambdas"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_policy" "dynamodb_full_access_policy" {
  name        = "dynamodb_full_access_policy"
  description = "Policy for full access to DynamoDB"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = "dynamodb:*",
        Effect   = "Allow",
        Resource = "arn:aws:dynamodb:us-east-1:144131464452:table/*"
      }
    ]
  })
}

resource "aws_iam_policy_attachment" "dynamodb_policy_attachment" {
  name       = "dynamodb_policy_attachment"
  policy_arn = aws_iam_policy.dynamodb_full_access_policy.arn
  roles      = [aws_iam_role.iam_for_cloud_resume_lambdas.name]
}

data "archive_file" "postVisitors-lambda" {
  type        = "zip"
  source_file = "${path.module}/postVisitors/lambda_function.py"
  output_path = "${path.module}/postVisitors/postVisitors_function_payload.zip"
}

data "archive_file" "getVisitors-lambda" {
  type        = "zip"
  source_file = "${path.module}/getVisitors/lambda_function.py"
  output_path = "${path.module}/getVisitors/getVisitors_function_payload.zip"
}

resource "aws_lambda_function" "postVisitors_lambda" {
  filename      = "${path.module}/postVisitors/postVisitors_function_payload.zip"
  function_name = "postVisitors-terraform"
  role          = aws_iam_role.iam_for_cloud_resume_lambdas.arn
  handler       = "lambda_function.lambda_handler"
  timeout       = 10
  runtime       = "python3.9"
}

resource "aws_lambda_function" "getVisitors_lambda" {
  filename      = "${path.module}/getVisitors/getVisitors_function_payload.zip"
  function_name = "getVisitors-terraform"
  role          = aws_iam_role.iam_for_cloud_resume_lambdas.arn
  handler       = "lambda_function.lambda_handler"
  timeout       = 10
  runtime       = "python3.9"
}

#------------------------------------------------------------------------------
# API Gateway
#------------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "postVisitors_api" {
  body = jsonencode({
    openapi = "3.0.1"
    info = {
      title   = "postVisitors_api"
      version = "1.0"
    }
    paths = {
      "/POST" = {
        post = {
          x-amazon-apigateway-integration = {
            httpMethod           = "POST"
            payloadFormatVersion = "1.0"
            type                 = "HTTP_PROXY"
            uri                  = "https://ip-ranges.amazonaws.com/ip-ranges.json"
          }
        }
      }
    }
  })

  name = "postVisitors_api"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_deployment" "postVisitors_api" {
  rest_api_id = aws_api_gateway_rest_api.postVisitors_api.id

  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_rest_api.postVisitors_api.body))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "postVisitors_api" {
  deployment_id = aws_api_gateway_deployment.postVisitors_api.id
  rest_api_id   = aws_api_gateway_rest_api.postVisitors_api.id
  stage_name    = "prod"
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name = "/aws/api_gw/${aws_api_gateway_rest_api.postVisitors_api.name}"

  retention_in_days = 30
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.postVisitors_lambda.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.postVisitors_api.execution_arn}/*/*"
}
