variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_endpoint" {
  description = "Override endpoint for every AWS service (e.g. http://localhost:5000 for Moto). Null means real AWS."
  type        = string
  default     = null
}

variable "env" {
  type    = string
  default = "demo"
}

variable "tenants" {
  description = "One data bucket per tenant."
  type        = list(string)
  default     = ["acme", "globex", "initech"]
}
