# High-Availability TimescaleDB Cluster

Infrastructure-as-code for a self-managed, highly-available TimescaleDB cluster on AWS, built for a connected-vehicle telemetry platform. Deployed via a single CloudFormation template into an existing VPC — no manual SSH, no manual failover.

## What this is

- **3-node etcd cluster** as the distributed consensus store
- **2-node Postgres 16 + TimescaleDB** cluster under **Patroni**, with automated leader election and failover coordinated through etcd
- **Internal NLB** exposing a write endpoint (routes only to the current leader via Patroni's `/primary` health check) and a read endpoint (routes to leader + replica via `/read-only`)
- **pgBackRest** backups to S3 (weekly full, daily incremental, WAL for point-in-time recovery)
- **Parquet cold-archival**: TimescaleDB chunks older than 90 days are exported to S3 as Parquet and dropped from the live database
- Access via **AWS SSM** only (no SSH, no open port 22)

## Repo structure

The cluster deploys from **one CloudFormation template**. Everything below `schema/`, `config/`, `scripts/`, and `systemd/` is *not* separately deployed — it's the real logic that gets baked into that template's EC2 UserData via heredocs, pulled out here so it reads as actual code instead of bash-string soup.

```
ha-timescaledb-cluster/
├── README.md
├── infrastructure/
│   └── timescaledb-ha-stack.yaml      # the single deployable CloudFormation template
├── schema/
│   └── vehicle_snapshots.sql          # hypertable DDL, compression policy
├── config/
│   ├── patroni.yml.template           # Patroni config (etcd hosts, failover tuning, TLS, pg_hba)
│   └── pgbackrest.conf.template       # backup repo config (S3 target, retention)
├── scripts/
│   ├── post_bootstrap.sh              # loads schema.sql once, on cluster init
│   ├── is_leader.sh                   # queries Patroni's REST API to check leader status
│   ├── backup.sh                      # weekly full / daily incremental, leader-only
│   ├── archive.sh                     # wraps archive_chunks.py with correct OS user + env
│   ├── archive_chunks.py              # exports chunks >90 days to Parquet in S3, then drops them
│   └── initial_backup.sh              # post-boot oneshot: waits for settled leader, runs first backup
└── systemd/
    ├── etcd.service
    ├── patroni.service
    └── tsdb-initial-backup.service
```

## Why this architecture

**Patroni + etcd over a managed HA offering (e.g. RDS Multi-AZ).** The goal was to actually understand and implement the failover mechanics — leader election, consensus, split-brain avoidance — rather than delegate it to a managed service. etcd holds cluster state and the leader lock; Patroni watches it and promotes a replica if the leader's lease expires. `config/patroni.yml.template` shows the actual failover tuning (`ttl`, `loop_wait`, `retry_timeout`, `maximum_lag_on_failover`).

**NLB with two listener ports instead of one.** Writes must always land on the leader, but reads can be safely spread across the leader and replica. The write target group only passes traffic to whichever node Patroni currently reports as `/primary` (`scripts/is_leader.sh` implements this same check for the backup/archive cron jobs), so failover is transparent to clients reconnecting on the same endpoint.

**Pre-created ENIs instead of relying on instance-assigned IPs.** etcd's cluster membership and Patroni's etcd host list both need static addresses at boot time, before instances exist. Pre-creating the ENIs means every node's IP is known upfront and wired in via CloudFormation's `!GetAtt` — and an ENI survives instance replacement, so a replaced node reattaches to the same IP and rejoins cleanly.

**Parquet cold-archival instead of relying only on TimescaleDB's native compression.** Compression keeps data queryable but doesn't reduce storage indefinitely. `scripts/archive_chunks.py` handles data past its 90-day operationally-useful window: export to columnar Parquet in S3, then `drop_chunks` — a much better cost profile for data kept for compliance/analytics but rarely queried live. It also checks `pg_is_in_recovery()` first so only the leader ever runs the job.

**Backups gated behind `is_leader.sh` rather than running on every node.** pgBackRest only needs to run against the current leader; running it on a replica too would be redundant and could race with WAL state. `initial_backup.sh` polls for a *settled* leader after boot rather than assuming the first-booted node wins, since Patroni's election isn't instant.

## Deploying

```bash
aws cloudformation deploy \
  --template-file infrastructure/timescaledb-ha-stack.yaml \
  --stack-name tsdb-ha \
  --parameter-overrides VpcId=<vpc-id> SubnetIdA=<subnet-a> SubnetIdB=<subnet-b> SubnetIdC=<subnet-c> VpcCidr=<vpc-cidr> \
  --capabilities CAPABILITY_IAM
```

## Known limitations (being upfront)

- TLS certs are self-signed — fine for internal traffic in this setup, would need CA-backed certs for production
- **`config/patroni.yml.template` has hardcoded superuser/replication passwords** (`testpass123` / `replpass123`) — fine for a disposable test stack, but before showing this repo around, swap these for CloudFormation `NoEcho` parameters or Secrets Manager references. Worth fixing before this is public-facing.
- Test defaults use `t4g.micro`/`t4g.small` instances and an 8GB volume — sized for demonstrating the mechanism, not production load
- No automated chaos/failover testing included; failover behavior was validated manually
- This is one monolithic CloudFormation template, not true nested stacks — the `schema/`, `config/`, `scripts/`, `systemd/` files above are extracted for readability, not independently deployed
