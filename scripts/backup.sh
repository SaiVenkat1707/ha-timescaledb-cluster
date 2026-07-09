#!/bin/bash
/opt/is_leader.sh || exit 0
sudo -u postgres pgbackrest --stanza=tsdb stanza-create 2>/dev/null || true
if [ "$(date +%u)" = "7" ]; then T=full; else T=incr; fi
sudo -u postgres pgbackrest --stanza=tsdb --type=$T backup
