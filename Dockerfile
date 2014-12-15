FROM ruby:latest
MAINTAINER  Ian Blenke <ian@blenke.com>

RUN echo "gem: --no-document --no-ri --no-rdoc\n" >> ~/.gemrc

# Install prerequisites.
RUN apt-get update && \
    apt-get install -yq libcurl4-openssl-dev && \
    apt-get clean

RUN gem install fluentd && \
	fluent-gem install \
		fluent-plugin-elasticsearch \
		fluent-plugin-record-reformer \
		fluent-plugin-cloudwatch \
		fluent-plugin-cloudwatch-logs \
		fluent-plugin-aqmp2 \
		fluent-plugin-s3

ADD https://github.com/kelseyhightower/confd/releases/download/v0.7.1/confd-0.7.1-linux-amd64 /usr/local/bin/confd

RUN chmod +x /usr/local/bin/confd

ADD fluentd.toml      /etc/confd/conf.d/fluentd.toml
ADD fluentd.conf.tmpl /etc/confd/templates/fluentd.conf.tmpl

ADD run.sh /run.sh
RUN chmod +x /run.sh

# expose in_tcp so we can pipe things like journald to fluentd
Expose 5170 5170/udp

VOLUME '/data'

#USER daemon

CMD ["/run.sh"]



