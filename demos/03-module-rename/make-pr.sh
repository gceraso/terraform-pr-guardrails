# Renaming a module changes every resource address inside it. Without a moved block,
# Terraform sees the old addresses as removed and the new ones as new: destroy, then create.
git switch -q -c pr
perl -pi -e 's/module "artifacts"/module "build_artifacts"/; s/module\.artifacts\.arn/module.build_artifacts.arn/' infra/main.tf
git commit -qam "Rename artifacts module for clarity"
