#!/bin/bash

# Fail fast, including pipelines
set -eo pipefail

# Set FLUENTD_TRACE to enable debugging
[[ $FLUENTD_TRACE ]] && set -x

# Configuration defaults
VOLUME_PATH=${VOLUME_PATH:-/data/fluentd}
BUFFER_PATH=${BUFFER_PATH:-${VOLUME_PATH}/buffer}
S3_PATH=${S3_PATH:-${VOLUME_PATH}/s3}
OUTPUT_PATH=${OUTPUT_PATH:-${VOLUME_PATH}/output}
SUPERVISORD_LOGS=${SUPERVISORD_LOGS:-${VOLUME_PATH}/supervisor}
DEBUG_LOG=${DEBUG_LOG:-/data/fluentd/output/debug}

CONFD_ARGS="${CONFD_ARGS:--quiet=true}"

# Ensure the paths exist
mkdir -p /etc/fluent $OUTPUT_PATH $BUFFER_PATH $S3_PATH $SUPERVISORD_LOGS

# Open up the number of filehandles from the default 1024 for fluentd
ulimit -n 65536

# Linkages to other containers override passed environment variables
if [ -n "${ETCD_PORT_4001_TCP_ADDR}" ]; then
  export ETCD_IP=${ETCD_PORT_4001_TCP_ADDR}
  export ETCD_PORT=4001
  export ETCD_ADDR=${ETCD_PORT_4001_TCP_ADDR}:4001
fi

if [ -n "${ELASTICSEARCH_PORT_9200_TCP_ADDR}" ]; then
  export ES_HOST=${ELASTICSEARCH_PORT_9200_TCP_ADDR}
  export ES_PORT=9200
fi

# Prepare default local etcd
ETCD_DIR_FOR_ELASTICSEARCH_HOSTS="${ETCD_DIR_FOR_ELASTICSEARCH_HOSTS:-/services/elasticsearch_logging/hosts}"
ETCD_PORT=${ETCD_PORT:-4001}
ETCD_IP=${ETCD_IP:-127.0.0.1}
ETCD_ADDR=${ETCD_ADDR:-${ETCD_IP}:${ETCD_PORT}}
ETCD_IP=$(echo $ETCD_ADDR | cut -d: -f1) # Recover ETCD_IP in case only ETCD_ADDR was specified
ETCD_BIND_ADDR=${ETCD_ADDR}
ETCD_PEER_ADDR=${ETCD_IP}:${ETCD_PEER_PORT:-7001}
ETCD_PEER_BIND_ADDR=${ETCD_PEER_ADDR}

export ETCD_DIR_FOR_ELASTICSEARCH_HOSTS ETCD_PORT ETCD_IP ETCD_ADDR ETCD_IP ETCD_BIND_ADDR ETCD_PEER_ADDR ETCD_PEER_BIND_ADDR

# Point etcdctl at the etcd address
ETCDCTL_PEERS=${ETCD_ADDR}
export ETCDCTL_PEERS

# If no external etcd is referenced, start a local one
if [ "${ETCD_ADDR}" = "127.0.0.1:4001" ]; then

  # If an external etcd isn't in use, we default to a single ElasticSearch host
  export ES_HOST=${ES_HOST:-172.17.42.1}
  export ES_PORT=${ES_PORT:-9200}

  # configure supervisord to start a standalone local etcd
  cat > /etc/supervisor/conf.d/etcd.conf <<EOF
[program:etcd]
command=/usr/local/bin/etcd
priority=10
directory=/tmp
process_name=%(program_name)s
user=root
autostart=true
autorestart=true
stopsignal=INT
stopasgroup=false
stdout_logfile=${SUPERVISORD_LOGS}/%(program_name)s.log
stderr_logfile=${SUPERVISORD_LOGS}/%(program_name)s.log
EOF

fi

# If a single ElasticSearch host was implied, ensure that it is registered in etcd
if [ -n "$ES_HOST" ]; then

  # configure supervisord to initially populate the standalone etcd pointing at the lone ElasticSearch host

  cat > /etcdctl.sh <<EOF
#!/bin/bash
source /.profile
while ! etcdctl ls / > /dev/null 2>&1 ; do echo Waiting for etcd to start; sleep 5; done ;
export ETCDCTL_PEERS=${ETCDCTL_PEERS};
echo ${ES_HOST}:${ES_PORT} | etcdctl set ${ETCD_DIR_FOR_ELASTICSEARCH_HOSTS}/${ES_HOST}
EOF

  chmod 755 /etcdctl.sh

  cat > /etc/supervisor/conf.d/etcdctl.conf <<EOF
[program:etcdctl]
command=/bin/bash /etcdctl.sh
priority=20
numprocs=1
autostart=true
autorestart=false
exitcodes=0,4
stdout_events_enabled=true
stderr_events_enabled=true
EOF

fi

# Configure the global supervisord settings
cat > /etc/supervisor/conf.d/supervisord.conf <<EOF
[supervisord]
nodaemon = true

[eventlistener:stdout] 
command = supervisor_stdout 
buffer_size = 100 
events = PROCESS_LOG 
result_handler = supervisor_stdout:event_handler
EOF

# Prepare supervisord program:confd
cat > /confd.sh <<EOF
#!/bin/bash
source /.profile
while ! etcdctl ls / > /dev/null 2>&1 ; do echo Waiting for etcd to start; sleep 5; done ;
exec /usr/local/bin/confd -watch ${CONFD_ARGS} -node ${ETCD_ADDR} -config-file /etc/confd/conf.d/fluentd.conf.toml
EOF

chmod 755 /confd.sh

cat > /etc/supervisor/conf.d/confd.conf <<EOF
[program:confd]
command=/bin/bash /confd.sh
priority=30
numprocs=1
autostart=true
autorestart=true
stdout_events_enabled=true
stderr_events_enabled=true
EOF

# Dynamically generate the confd configuration toml for fluentd

mkdir -p /etc/confd/conf.d/

cat <<TOML > /etc/confd/conf.d/fluentd.conf.toml
[template]
src	= "fluentd.tmpl"
dest	= "/etc/fluent/fluent.conf"
keys	= [
    "${ETCD_DIR_FOR_ELASTICSEARCH_HOSTS}/"
]
check_cmd = "/usr/local/bundle/bin/fluentd -q --dry-run -c {{ .src }}"
reload_cmd = "/usr/bin/supervisorctl restart fluentd"
TOML

# This is to stop fluentd from logging to stdout
# As logspout is likely tailing docker's logs, we must do this to avoid a feedback loop.
cat <<WRAPPER > /fluentd.sh
#!/bin/bash
exec /usr/local/bundle/bin/fluentd -q -c /etc/fluent/fluent.conf > /dev/null
WRAPPER

chmod 755 /fluentd.sh

cat <<FLUENTD > /etc/supervisor/conf.d/fluentd.conf
[program:fluentd]
command=/bin/bash /fluentd.sh
priority=40
numprocs=1
autostart=true
autorestart=true
stdout_events_enabled=true
stderr_events_enabled=true
FLUENTD

cat <<EOF > /etc/fluent/fluent.conf
<source>
  type monitor_agent
  bind 0.0.0.0
  port 24220
</source>
EOF

# Dynamically initially auto-generate the confd template for the fluentd config

mkdir -p /etc/confd/templates/

cat <<TMPL > /etc/confd/templates/fluentd.tmpl
{{\$data := ls "${ETCD_DIR_FOR_ELASTICSEARCH_HOSTS}"}}
<source>
  type monitor_agent
  bind 0.0.0.0
  port 24220
</source>
<source>
  type tcp
  port 5170
  format json
  source_host_key client_host
  tag system
</source>
<source>
  type tcp
  port 5171
  format nginx
  source_host_key client_host
  tag nginx
</source>
<match system>
  type record_reformer
  renew_record false
  enable_ruby false
  remove_keys __CURSOR,__REALTIME_TIMESTAMP,__MONOTONIC_TIMESTAMP,_BOOT_ID,_UID,_GID,_CAP_EFFECTIVE,_SYSTEMD_SLICE,SYSLOG_IDENTIFIER,_SYSTEMD_CGROUP,_CMDLINE,_COMM
  tag system.clean
</match>
{{ if getenv "LOG_DOCKER_JSON" }}
<source>
  type tail
  path /var/lib/docker/containers/*/*-json.log
  pos_file /var/log/fluentd-docker.pos
  time_format %Y-%m-%dT%H:%M:%S
  tag docker.*
  format json
</source>
<match docker.var.lib.docker.containers.*.*.log>
  type record_reformer
  container_id ${tag_parts[5]}
  tag docker.all
</match>
{{ end }}
{{ if getenv "DEBUG_FLUENTD" }}
<match **>
  type file
  path /data/fluentd/output/debug
  append true
  time_slice_format %Y%m%d
  time_format %Y%m%dT%H%M%S%z
  flush_interval 5s
  utc
</match>
{{ end }}
{{ if getenv "ES_HOST" }}
<match **>
  type elasticsearch
  log_level debug
  include_tag_key true
  {{ if \$data }}
  hosts {{ join \$data "," }}
  port 9200
  {{ else }}
  hosts ${ES_HOST:-172.17.42.1}
  port ${ES_PORT:-9200}
  {{ end }}
  logstash_format true
  reload_on_failure true
  reload_connections true
  buffer_type file
  buffer_path ${BUFFER_PATH}
  flush_interval 5s
  max_retry_wait 300s
  retry_wait 5s
  disable_retry_limit
</match>
{{ end }}
{{ if getenv "AWS_ACCESS_KEY_ID" }}
<match **>
   type s3
   aws_key_id {{ getenv "AWS_ACCESS_KEY_ID" }}
   aws_sec_key {{ getenv "AWS_SECRET_ACCESS_KEY" }}
   s3_bucket {{ getenv "AWS_S3_BUCKET" }}
   s3_region {{ getenv "AWS_REGION" }}
   use_ssl
   path logs/
   buffer_path ${S3_PATH}
   time_slice_format %Y%m%d%H
   time_slice_wait 10m
   format json
   include_time_key true
   include_tag_key true
   utc
   buffer_chunk_limit 256m
</match>
{{ end }}
{{ if getenv "LOG_GROUP_NAME" }}
<match **>
   type cloudwatch_logs
   log_group_name {{ getenv "LOG_GROUP_NAME" }}
   log_stream_name {{ getenv "LOG_STREAM_NAME" }}
   auto_create_stream true
</match>
{{ end }}
TMPL

env | xargs -l1 echo export > /.profile

# supervisord will error out if this does not exist (think: mounted volume)
mkdir -p /var/log/supervisor

# start supervisord
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf
