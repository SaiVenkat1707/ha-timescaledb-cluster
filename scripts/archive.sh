#!/bin/bash
# Run the archival job AS the postgres OS user so local peer auth
# succeeds (cron invokes this as root; connecting as postgres over the
# unix socket requires the OS user to be postgres). Bucket/region are
# passed through into the postgres shell so boto3 can read them.
exec sudo -u postgres bash -c 'ARCHIVE_BUCKET="${ArchiveBucket}" REGION="${AWS::Region}" python3 /opt/archive_chunks.py'
