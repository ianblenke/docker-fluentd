#!/bin/bash

set -me

ulimit -n 65536

export ETCD_PORT=${ETCD_PORT:-4001}
export ETCD_IP=${ETCD_IP:-172.17.42.1}
export ETCD=$ETCD_IP:4001

logger -t 'fluentd' "booting container. ETCD: $ETCD"
logger -t 'fluentd' "starting"
mkdir -p /etc/fluent /data/fluentd/buffer /data/fluentd/s3 /data/fluentd/output
/usr/local/bin/confd -watch -quiet=false -debug -node $ETCD -config-file /etc/confd/conf.d/fluentd.toml &

touch '/var/log/fluentd.log'
tail -f /var/log/fluentd.log

