# docker-fluentd

This docker image spawns a fluentd configured for elasticsearch and optionally S3 and CloudWatch logs if the appropriate environment variables are set.

etcd+confd dynamically create a config file allowing fluentd to talk to any of the elasticsearch nodes in the cluster, but otherwise defaults to 172.17.42.1:9200

More docs as this progresses
