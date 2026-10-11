# The branch only touches the KMS key description. While it sat open, main gained a
# reports bucket. The branch's diff against its merge-base is still one clean line, but its
# plan against current state deletes the reports bucket -- the branch never had it.
git switch -q -c pr
perl -pi -e 's/description             = "\$\{var.env\} data encryption key"/description             = "\${var.env} data encryption key (tenant data)"/' infra/main.tf
git commit -qam "Clarify what the data key encrypts"
git switch -q main
cat >>infra/main.tf <<'HCL'

resource "aws_s3_bucket" "reports" {
  bucket = "${var.env}-reports"
}
HCL
git commit -qam "Add reports bucket"
