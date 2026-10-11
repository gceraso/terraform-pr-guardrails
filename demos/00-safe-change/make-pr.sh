# An in-place update to a stateful resource: nothing is destroyed, so it passes.
git switch -q -c pr
perl -0pi -e 's/(  hash_key     = "LockID"\n)/$1\n  tags = {\n    team = "platform"\n  }\n/' infra/main.tf
git commit -qam "Tag the lock table with its owning team"
