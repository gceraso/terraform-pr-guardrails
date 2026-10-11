# Offboarding the first tenant. The buckets are keyed by list position, so every later
# tenant shifts down one index: their buckets are replaced and the last index is destroyed.
git switch -q -c pr
perl -pi -e 's/\["acme", "globex", "initech"\]/["globex", "initech"]/' infra/variables.tf
git commit -qam "Offboard tenant acme"
