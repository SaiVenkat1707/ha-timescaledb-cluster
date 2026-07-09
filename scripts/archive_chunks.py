#!/usr/bin/env python3
import os, sys, io
import psycopg2, pyarrow as pa, pyarrow.parquet as pq, boto3
bucket = os.environ["ARCHIVE_BUCKET"]
region = os.environ["REGION"]
conn = psycopg2.connect("dbname=postgres user=postgres host=/var/run/postgresql")
conn.autocommit = True
cur = conn.cursor()
cur.execute("SELECT pg_is_in_recovery()")
if cur.fetchone()[0]:
    sys.exit(0)  # replica: do nothing
cur.execute("""SELECT chunk_schema, chunk_name FROM timescaledb_information.chunks
               WHERE hypertable_name='vehicle_snapshots'
                 AND range_end < now() - INTERVAL '90 days'""")
chunks = cur.fetchall()
if not chunks:
    sys.exit(0)
s3 = boto3.client("s3", region_name=region)
ok = True
for schema, name in chunks:
    try:
        rc = conn.cursor()
        rc.execute('SELECT * FROM "%s"."%s"' % (schema, name))
        cols = [d[0] for d in rc.description]
        data = {c: [] for c in cols}
        for row in rc.fetchall():
            for c, v in zip(cols, row):
                data[c].append(None if v is None else str(v))
        buf = io.BytesIO()
        pq.write_table(pa.table(data), buf)
        s3.put_object(Bucket=bucket, Key="vehicle_snapshots/%s.parquet" % name, Body=buf.getvalue())
        rc.close()
    except Exception as e:
        sys.stderr.write("failed %s: %s\n" % (name, e))
        ok = False
if ok:
    cur.execute("SELECT drop_chunks('vehicle_snapshots', older_than => INTERVAL '90 days')")
