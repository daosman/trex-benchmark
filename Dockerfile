FROM quay.io/centos/centos:stream9

ARG TREX_VERSION
ENV TREX_VERSION ${TREX_VERSION}

# install requirements
RUN dnf install -y --nodocs git wget procps python3 vim python3-pip pciutils gettext https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm && dnf clean all
RUN dnf install -y --nodocs hostname iproute net-tools ethtool nmap iputils perf numactl sysstat htop rdma-core-devel libibverbs libibverbs-devel net-tools dmidecode tmux jq rsync && dnf clean all

# install trex server
WORKDIR /opt/
RUN wget --no-check-certificate https://trex-tgn.cisco.com/trex/release/v${TREX_VERSION}.tar.gz && \
   tar -xzf v${TREX_VERSION}.tar.gz && \
   mv v${TREX_VERSION} trex && \
   rm v${TREX_VERSION}.tar.gz

COPY ./run.sh /usr/bin/run.sh
RUN chmod +x /usr/bin/run.sh

COPY ./rfc-2544.sh /usr/bin/rfc-2544.sh
RUN chmod +x /usr/bin/rfc-2544.sh

WORKDIR /opt/trex
