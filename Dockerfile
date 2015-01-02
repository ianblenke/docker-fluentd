FROM ruby:latest
MAINTAINER  Ian Blenke <ian@blenke.com>

RUN echo "gem: --no-document --no-ri --no-rdoc\n" >> ~/.gemrc

# Install prerequisites.
RUN apt-get update && \
    apt-get install -yq libcurl4-openssl-dev supervisor python-pip && \
    apt-get clean

RUN gem install fluentd && \
	fluent-gem install \
		fluent-plugin-elasticsearch \
		fluent-plugin-record-reformer \
		fluent-plugin-cloudwatch \
		fluent-plugin-cloudwatch-logs \
		fluent-plugin-s3

RUN pip install supervisor-stdout

ADD https://github.com/kelseyhightower/confd/releases/download/v0.7.1/confd-0.7.1-linux-amd64 /usr/local/bin/confd

RUN curl -L  https://github.com/coreos/etcd/releases/download/v0.4.6/etcd-v0.4.6-linux-amd64.tar.gz -o /tmp/etcd-v0.4.6-linux-amd64.tar.gz ; \
    tar xzf /tmp/etcd-v0.4.6-linux-amd64.tar.gz -C /tmp ; \
    cd /tmp/etcd-v0.4.6-linux-amd64 ; \
    cp -f etcd /usr/local/bin/etcd ; \
    cp -f etcdctl /usr/local/bin/etcdctl ; \
    cd /tmp ; \
    rm -fr /tmp/etcd-v0.4.6-linux-amd64*

RUN chmod +x /usr/local/bin/confd /usr/local/bin/etcd /usr/local/bin/etcdctl

ADD run.sh /run.sh
RUN chmod +x /run.sh

# expose in_tcp so we can pipe things like journald to fluentd
Expose 5170 5170/udp

VOLUME /data

#USER daemon

CMD ["/run.sh"]

