#!/bin/bash
# Wait (long, no premature give-up) until this node is the settled leader.
# If it becomes a stable replica instead, exit cleanly - the leader's
# copy of this oneshot performs the backup.
for i in $(seq 1 60); do
  if /opt/is_leader.sh; then
    sudo -u postgres pgbackrest --stanza=tsdb stanza-create || true
    sudo -u postgres pgbackrest --stanza=tsdb --type=full backup || true
    exit 0
  fi
  sleep 15
done
exit 0
