# The same rename with a moved block: a state-only change, nothing is recreated.
git switch -q -c pr
perl -pi -e 's/module "artifacts"/module "build_artifacts"/; s/module\.artifacts\.arn/module.build_artifacts.arn/' infra/main.tf
cat >>infra/main.tf <<'HCL'

moved {
  from = module.artifacts
  to   = module.build_artifacts
}
HCL
git commit -qam "Rename artifacts module for clarity, with a moved block"
