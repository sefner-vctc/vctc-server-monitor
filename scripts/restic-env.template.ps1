# Copy this file to C:\Scripts\restic-env.ps1 and replace placeholders.
# This file sets environment variables used by Restic.
# Important:
# - Use the format: s3:https://s3.us-east-1.wasabisys.com/YOUR-BUCKET
# - A new Wasabi bucket is not automatically a Restic repository.
# - For a brand-new bucket, run `restic init` once before the first backup.

$env:RESTIC_REPOSITORY = "s3:https://s3.us-east-1.wasabisys.com/YOUR-BUCKET"
$env:RESTIC_PASSWORD = "YOUR_REPOSITORY_PASSWORD"
$env:AWS_ACCESS_KEY_ID = "YOUR_WASABI_ACCESS_KEY"
$env:AWS_SECRET_ACCESS_KEY = "YOUR_WASABI_SECRET_KEY"
