terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# aws_endpoint points every service at a local AWS emulator (Moto). Left null, the
# provider talks to real AWS and none of the skip_* shortcuts apply.
provider "aws" {
  region = var.region

  skip_credentials_validation = var.aws_endpoint != null
  skip_requesting_account_id  = var.aws_endpoint != null
  skip_metadata_api_check     = var.aws_endpoint != null
  s3_use_path_style           = var.aws_endpoint != null

  endpoints {
    dynamodb = var.aws_endpoint
    iam      = var.aws_endpoint
    kms      = var.aws_endpoint
    s3       = var.aws_endpoint
    sts      = var.aws_endpoint
  }

  # No default_tags: Moto drops S3 bucket tags, so they would plan as a change on every
  # run and bury the signal in each PR comment.
}
