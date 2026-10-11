module "artifacts" {
  source = "./modules/bucket"
  name   = "${var.env}-build-artifacts"
}

module "logs" {
  source = "./modules/bucket"
  name   = "${var.env}-access-logs"
}

# Indexed by position, not by name -- see demos/04-count-index-shift.
resource "aws_s3_bucket" "tenant" {
  count  = length(var.tenants)
  bucket = "${var.env}-tenant-${var.tenants[count.index]}"
}

resource "aws_dynamodb_table" "locks" {
  name         = "${var.env}-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

resource "aws_kms_key" "data" {
  description             = "${var.env} data encryption key"
  deletion_window_in_days = 7
}

resource "aws_iam_role" "ci" {
  name = "${var.env}-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ci_artifacts" {
  name = "artifacts-write"
  role = aws_iam_role.ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject"]
      Resource = "${module.artifacts.arn}/*"
    }]
  })
}
