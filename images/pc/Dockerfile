FROM lscr.io/linuxserver/firefox@sha256:0ae2edfb3d463f09309b565ea5d7262713d0fa171ef23f03efd101d5f488fdea
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      iproute2 iputils-ping openssh-server tcpdump ethtool netcat-openbsd dnsutils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
