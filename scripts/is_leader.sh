#!/bin/bash
# Patroni's REST API binds to the node's private IP (not 127.0.0.1),
# so we must query that IP. Derive it from IMDS at runtime.
TKN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
IP=$(curl -s -H "X-aws-ec2-metadata-token: $TKN" http://169.254.169.254/latest/meta-data/local-ipv4)
code=$(curl -s -o /dev/null -w "%{http_code}" http://$IP:8008/primary)
[ "$code" = "200" ]
