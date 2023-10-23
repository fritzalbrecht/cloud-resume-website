terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 4.0.0"
      configuration_aliases = [aws.main, aws.acm_provider]
    }
  }
}

provider "aws" {
  region = "us-east-1"
  alias  = "main"
}

provider "aws" {
  region = "us-east-1"
  alias  = "acm_provider"
}