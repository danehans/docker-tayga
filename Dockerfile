FROM ubuntu:16.04

MAINTAINER Daneyon Hansen <danehans@cisco.com>

ENV \
	TAYGA_CONF_DATA_DIR=/var/db/tayga \
	TAYGA_CONF_DIR=/usr/local/etc \
	TAYGA_CONF_IPV4_ADDR=172.18.0.100 \
	TAYGA_CONF_PREFIX=2001:db8:64:ff9b::/96 \
	TAYGA_CONF_DYNAMIC_POOL=172.18.0.128/25

RUN apt-get update && apt-get install -y \
    curl \
    iproute2 \
    pkg-config \
    && apt-get clean

RUN curl -O http://www.litech.org/tayga/tayga-0.9.2.tar.bz2 \
    && bzip2 -dk tayga-0.9.2.tar.bz2 \
    && tar -xvf tayga-0.9.2.tar \
    && cd tayga-0.9.2 \\
    && ./configure && make && make install

ADD docker-entry.sh /
RUN chmod +x /docker-entry.sh

ENTRYPOINT ["/docker-entry.sh"]