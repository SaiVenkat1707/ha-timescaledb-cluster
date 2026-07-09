#!/bin/bash
set -e
psql -U postgres -h /var/run/postgresql -f /etc/patroni/schema.sql
