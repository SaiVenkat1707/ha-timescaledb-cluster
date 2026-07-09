# TimescaleDB HA Stack — Production Handoff

Companion to `tsdb-ha-full.yaml`. This document captures everything that runs
automatically, every value hardcoded into the template, the known operational
behaviors, and the exact changes required to move from the small **test**
configuration to a **production** deployment.

The template has been deployed and validated end-to-end on a test stack:
cluster bootstrap, streaming replication, automatic failover, the dual NLB
endpoints, schema load with compression, automatic initial backup with WAL
archiving, and Parquet archival were all confirmed working from a clean boot.

---

## 1. Read this first — the four that bite hardest

1. **Scheduled jobs run on a clock (UTC):** backups at **02:00**, archival at **03:00**. They will not appear to "do anything" right after deploy — that is expected.
2. **Test passwords are hardcoded** (`testpass123`, `replpass123`). These MUST be replaced with AWS Secrets Manager before any production use.
3. **Both S3 buckets are set to `DeletionPolicy: Delete`** — deleting the CloudFormation stack destroys the backup and archive buckets *and their contents*. For production, change these to `Retain`.
4. **Failover causes a ~30-second window where the write endpoint (port 5432) refuses connections** while the NLB re-runs health checks. The consumer application must implement connection-retry logic.

---

## 2. Scheduled jobs (cron)

Defined in `/etc/cron.d/tsdb-jobs`, run as root, **leader-guarded** (they detect
the current leader and no-op on the replica).

| Job | Schedule (UTC) | What it does |
|-----|----------------|--------------|
| Backup | Daily **02:00** | Full backup on **Sundays**, incremental the other six days, to the backup S3 bucket. |
| Archival | Daily **03:00** | Exports chunks older than **90 days** to Parquet in the archive S3 bucket, then drops them from the database. |

Notes:
- Times are UTC because the instances run in UTC.
- Archival is a one-way cold-archive: once a chunk is exported and dropped it is
  **no longer queryable through TimescaleDB** — it lives only as a Parquet file
  in S3. This is intentional (data older than 90 days is not queried back).
- Logs: `/var/log/tsdb-backup.log` and `/var/log/tsdb-archive.log`.

---

## 3. Things that run automatically at boot

| Behavior | When | Notes |
|----------|------|-------|
| Schema load | Once, on the bootstrapping leader | Via Patroni `post_bootstrap`. Creates the `vehicle_snapshots` hypertable, compression config, etc. Replicates to the other node. |
| Replication | As Patroni starts | Patroni clones the second node from the leader and starts streaming. No manual `pg_basebackup`. |
| Automatic failover | Armed as Patroni starts | Coordinated via etcd. |
| Initial backup | Once, post-boot | A systemd oneshot (`tsdb-initial-backup.service`) waits until a leader has settled, then runs `stanza-create` + a first full backup. Non-blocking. |
| SSM agent | At boot | Installed/started best-effort so the node is reachable via Session Manager (no SSH). |

---

## 4. Hardcoded values

### Data lifecycle
| Value | Setting | Where |
|-------|---------|-------|
| Chunk interval | **1 day** | `create_hypertable` |
| Compression after | **7 days** | `add_columnstore_policy` |
| Archive + drop after | **90 days** | `archive_chunks.py` (`INTERVAL '90 days'`) |
| Backup retention | **4 full backups** | `repo1-retention-full=4` (~4 weeks given weekly fulls; older expired automatically) |
| Compression layout | segment by `vin`, order by `captured_at DESC` | schema |

### Network (all hardcoded, NOT parameters)
| Item | Value |
|------|-------|
| VPC CIDR | `10.0.0.0/16` |
| Public subnet | `10.0.0.0/24` (NAT only) |
| Private subnets | `10.0.1.0/24`, `10.0.2.0/24`, `10.0.3.0/24` (one per AZ) |
| etcd fixed IPs | `10.0.1.10`, `10.0.2.10`, `10.0.3.10` |
| DB fixed IPs | `10.0.1.20`, `10.0.2.20` |
| NLB ports | **5432** writes (leader only), **5433** reads (primary + replica) |
| Patroni REST | **8008**, bound to each node's private IP |
| etcd ports | **2379** client, **2380** peer |

> The DB user-data identifies each node by matching its own IP against these
> literals (e.g. `10.0.1.20` → names itself node-1). Changing the IP scheme
> means editing those checks in the user-data, not just the subnet definitions.

### Cluster behavior
| Item | Value | Meaning |
|------|-------|---------|
| `ttl` | 30 | Leader lease lifetime |
| `loop_wait` | 10 | Patroni poll interval |
| `retry_timeout` | 10 | DCS/PostgreSQL operation timeout |
| Failover time | ~30–60s | Detection + promotion |
| `failsafe_mode` | true | Keeps writes flowing if etcd quorum lost but replica reachable |
| `use_pg_rewind` | true | Recovered old leader rejoins without full reclone |
| etcd token | `tsdb-etcd` | |
| Patroni scope | `tsdb-cluster` | |

### Software versions
| Component | Version | Pinned? |
|-----------|---------|---------|
| PostgreSQL | 16 | yes (package) |
| TimescaleDB | 2.x (latest at install) | no — pulls latest |
| etcd | v3.5.13 | yes (parameter `EtcdVersion`) |
| OS | Ubuntu 22.04 ARM | yes (SSM AMI param) |
| Python libs (Patroni, pyarrow, boto3, psycopg2) | latest at build | **no** — a rebuild months later may pull newer versions |

---

## 5. Security posture

**Already in place:**
- Private subnets, no public IPs on DB/etcd nodes; outbound via NAT.
- Access via **SSM Session Manager only** — no SSH, no port 22.
- Least-privilege security groups (security-group-referenced, not broad CIDR), except the NLB ingress which is VPC-CIDR (`10.0.0.0/16`).
- TLS enforced for non-local Postgres connections (`hostssl`).
- EBS and S3 encrypted at rest (S3 = SSE-S3/AES256).
- S3 buckets block all public access; backup bucket versioned.
- IMDSv2 required on all instances.

**Must change for production:**
- **Passwords** → replace `testpass123` / `replpass123` with AWS Secrets Manager.
- **TLS certs** → replace the self-signed certs (generated at boot, 3650-day) with CA-backed certificates.
- **NLB ingress** → currently any source in `10.0.0.0/16`; scope to the consumer's security group.
- **S3 `DeletionPolicy`** → change both buckets from `Delete` to `Retain` so a stack delete does not wipe backups/archives.

---

## 6. Deliberately NOT included (do not assume coverage)

- **Monitoring / alerting** — no CloudWatch alarms, Prometheus, or Grafana. The cluster does not alert on disk pressure, replication lag, etcd node loss, backup failure, or stuck compression.
- **Consumer connection** — the Java/Fargate ingestion side is not part of this stack.
- **PITR restore drill** — backups and WAL archiving exist and are validated as *written*, but restoring from them has never been exercised. Do a restore test before relying on it.
- **Bulk / initial data load** — no tooling for loading historical data.
- **Schema migration tooling** — no mechanism for altering the hypertable later on large data.
- **Read routing** — the read endpoint (5433) sends reads to *both* primary and replica (`/read-only`). If reads should hit only the replica, that is a change.

---

## 7. Test → Production sizing changes

The template uses CloudFormation **parameters** for the items most likely to
change, so the common cases need no template edits — just different parameter
values at deploy time. A few items are hardcoded and require editing the YAML.

### 7a. Change via parameters (no YAML edit)

| Parameter | Test default | Suggested production | Rationale |
|-----------|--------------|----------------------|-----------|
| `DbInstanceType` | `t4g.micro` | `r7g.4xlarge` (or `r6i.4xlarge`) | DB nodes need real RAM; the chunk-interval / shared-buffers sizing assumes a memory-rich instance. Memory-optimized (r-family) is the right class for a time-series workload at ~20–25 GB/day. |
| `EtcdInstanceType` | `t4g.small` | `t4g.small` (keep) or `t4g.medium` | etcd is lightweight; small is genuinely fine. Bump to medium only if you see etcd latency. Do **not** over-provision etcd. |
| `DbVolumeSizeGb` | `8` | `1500` (1.5 TB) and up | At ~20–25 GB/day raw, with compression after 7 days and archival at 90 days, 1.5 TB is a reasonable starting point. Size against: (days of hot+compressed data retained on disk before the 90-day archival) × daily volume, plus headroom for WAL and backups staging. Re-evaluate once real compression ratios are known. |

### 7b. Requires editing the template

| Area | Test value | Production guidance |
|------|------------|---------------------|
| **EBS volume type / IOPS** | `gp3` default IOPS (3000) / 125 MB/s | For production write throughput, provision higher IOPS and throughput on the gp3 volumes (e.g. 6000–12000 IOPS, 250–500 MB/s), or move to `io2` if sustained low-latency writes demand it. This is set in the `BlockDeviceMappings` of each DB node. |
| **etcd node count** | 3 | Keep at **3** (survives one failure). Only consider 5 for very large multi-region setups — 5 increases write-quorum latency, so do not raise it without reason. |
| **DB node count** | 2 (1 primary + 1 replica) | 2 covers single-node failure. Add a second replica (3 total) if you want read-scaling headroom or to tolerate two simultaneous failures. Adding a replica means a third DB instance + IP + target-group registration. |
| **NAT gateway** | 1 (single AZ) | A single NAT is an availability risk: if its AZ fails, the private nodes lose outbound. For production, deploy **one NAT gateway per AZ** with per-AZ private route tables. (Bootstrap-time only matters for installs; steady-state Postgres traffic does not need NAT — but backups/archival to S3 do, unless using the S3 VPC endpoint, which this template includes.) |
| **Backup retention** | 4 fulls | Set `repo1-retention-full` to match your compliance window (e.g. EU Data Act retention requirements). |
| **Multi-AZ NLB** | 2 subnets (a, b) | The NLB spans the two DB subnets. If you add a third DB node in AZ-c, add that subnet to the NLB. |
| **PostgreSQL tuning** | defaults from Patroni params | Tune `shared_buffers`, `work_mem`, `max_connections`, `effective_cache_size`, WAL settings to the chosen instance size. These belong in the Patroni `parameters` block. A `t4g.micro` and an `r7g.4xlarge` need very different values. |

### 7c. Cost note

In the test config the only meaningfully-priced resources are the **NAT
gateway** (~$32/mo) and the **NLB** (~$16/mo); everything else on small
instances is cents. In production the **DB instances, EBS, and per-AZ NAT
gateways** become the dominant costs, scaling with the choices above. After any
stack deletion, confirm the NAT gateway(s), NLB, Elastic IP(s), and any EBS
snapshots are gone — orphaned versions of those are the main runaway-cost risk.

---

## 8. Validation status (what was actually tested)

Confirmed working on a clean test deploy, no manual intervention:
- etcd quorum, Patroni bootstrap, schema load with compression configured.
- Streaming replication, Lag 0.
- Automatic failover (leader stopped → replica promoted, timeline incremented, old node rejoined as replica).
- NLB write endpoint (→ leader) and read endpoint.
- Automatic initial backup + continuous WAL archiving to S3 (keyless via IAM role).
- Parquet archival: chunks older than 90 days exported to S3 and dropped; recent data retained; exported Parquet confirmed readable.

Bugs found and fixed during validation (all resolved in the current template):
1. `pip --break-system-packages` unsupported on the AMI's pip → fallback added.
2. Patroni data directory owned by root → `chown postgres` added.
3. pgBackRest required IAM-role auth → `repo1-s3-key-type=auto` added.
4. Archival job hit peer-auth running as root → now runs as the `postgres` user.
5. Leader-detection (`is_leader.sh`) queried `127.0.0.1` but Patroni binds the node IP → fixed to query the node IP; initial backup moved to a post-boot systemd oneshot to avoid a boot-time race.
