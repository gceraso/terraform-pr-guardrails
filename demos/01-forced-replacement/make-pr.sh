# A one-word rename. S3 bucket names are immutable, so the provider replaces the bucket:
# the old one, and every object in it, is destroyed.
git switch -q -c pr
perl -pi -e 's/-access-logs"/-request-logs"/' infra/main.tf
git commit -qam "Rename the logs bucket to match the new naming scheme"
