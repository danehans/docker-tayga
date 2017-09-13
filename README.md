# Quick Setup

Create the Docker network:
```
sudo docker network create --subnet 172.18.0.0/16 --ipv6 --subnet=fd00:dead:beef::/48 test >/dev/null
```

Run the Tayga container
```
sudo docker run -d --net test --ip 172.18.0.100 --ip6 fd00:dead:beef::100 --dns 8.8.8.8 \
--name tayga --hostname tayga --privileged=true --sysctl net.ipv6.conf.all.disable_ipv6=0 \
--sysctl net.ipv6.conf.all.forwarding=1 danehans/tayga:latest
```

You can pass the `-e` flag in the above `docker run` command to customize your docker-tayga
deployment using environment variables. The following environment variables are supported with default values:
```
TAYGA_CONF_DATA_DIR=/var/db/tayga
TAYGA_CONF_DIR=/usr/local/etc
TAYGA_CONF_IPV4_ADDR=172.18.0.100
TAYGA_CONF_PREFIX=2001:db8:64:ff9b::/96
TAYGA_CONF_DYNAMIC_POOL=172.18.0.128/25
```

# Detailed Setup
[Tayga](http://www.litech.org/tayga/) is used for providing NAT64 translation services. Tayga works hand-in-hand with DNS64 allowing IPv6-only clients to access resources over an IPv4 network. Start by `ssh`ing to a Docker host and configure your environment variables:
```
# TAYGA_CONF_IPV4_ADDR is the IPv4 address of the Tayga container.
# The TAYGA_CONF_IPV4_ADDR IP is derived from the Docker test network created in a later step.
# TAYGA_CONF_DYNAMIC_POOL is the IPv4 address pool Tayga uses for 6-to-4 translation.
# The TAYGA_CONF_DYNAMIC_POOL address block is a subset of addresses from the Docker 'test' network.
export TAYGA_CONF_IPV4_ADDR=172.18.0.100
export TAYGA_IPV6_ADDR=fd00:dead:beef::100
export TAYGA_CONF_DYNAMIC_POOL=172.18.0.128/25
export TAYGA_CONF_PREFIX=2001:db8:64:ff9b::/96
```

Before starting any containers, you must create a Docker network. __Note:__ At the time of this writing, Docker does not support NATing IPv6 traffic.

```
sudo docker network create --subnet 172.18.0.0/16 --ipv6 --subnet=fd00:dead:beef::/48 test >/dev/null
```

Your Docker host needs to know how to get to Tayga's IPv4 prefix. Create a static route:
```
sudo ip route add $TAYGA_CONF_DYNAMIC_POOL via $TAYGA_CONF_IPV4_ADDR
```

__Note:__ NAT64 translates sources addresses `fd00:dead:beef::/48` to the IPv4 pool ($TAYGA_CONF_DYNAMIC_POOL) derived from `172.18.0.0/16`.

Run Tayga container. Tayga is dual-stack and by default uses Google's public DNS server (IPv4) for name resolution:
```
sudo docker run -d --net test --ip 172.18.0.100 --ip6 fd00:dead:beef::100 --dns 8.8.8.8 \
--name tayga --hostname tayga --privileged=true --sysctl net.ipv6.conf.all.disable_ipv6=0 \
--sysctl net.ipv6.conf.all.forwarding=1 danehans/tayga:latest
```

# DNS64 Container

DNS64 is implemented using IPv6-only Bind9 on Docker v17.07.0-ce. Follow the [installation guide](https://docs.docker.com/engine/installation/linux/ubuntu/) for installing Docker on Ubuntu 16.04.2.

Create file `/etc/bind9/named.conf` on your GCE VM. This file will be bind mounted to the bind9 container. `2001:db8:64:ff9b::0808:0808` is the _synthesized_ IPv4 address of the Google IPv4 DNS server `8.8.8.8`. `2001:db8:64:ff9b::/96` is the IPv6 prefix to which embedded IPv4 addresses are appended. This prefix must match the prefix used for NAT64 (i.e. tayga.conf prefix):
```
sudo mkdir -p /etc/bind9
sudo bash -c 'cat << EOF > /etc/bind9/named.conf
options {
  directory "/var/bind";

  # Allow DNS queries from any source.
  # Restrict to specific client IPs for production deployments.
  allow-query { any; };

  # The synthesized address of Google DNS 8.8.8.8
  # The address prefix (64:ff9b::) should be updated
  # if the directive "dns64 64:ff9b::/96" below is changed.
  forwarders {
    2001:db8:64:ff9b::0808:0808;
  };

  auth-nxdomain no; # conform to RFC1035
  listen-on-v6 { any; };

  # Prefix used to synthesize IPv4 addresses.
  # Should match your NAT64 configuration
  dns64 2001:db8:64:ff9b::/96 {
    exclude { any; };
  };
};
EOF'
```
__Note:__ The `exclude { any; }` directive tells bind9 to exclude providing any `AAAA` records to DNS queries, even for dual stack hosts such as `www.google.com`. This will cause name resolution to always provide an `A` record, which uses an IPv4 address.

Run the bind9 container. __Note:__ `--ip6` and `--dns` values should match as the bind9 container uses it's self for name resolution and is configured to forward DNS requests to the synthesized address (`2001:db8:64:ff9b::0808:0808`) of Google's Public DNS server `8.8.8.8` using NAT64. The `-v` option bind mounts `/etc/bind9/named.conf` on your host to `/etc/bind/named.conf` inside the container and `--net` connects the container to the `test` Docker bridge network:
```
sudo docker run -d --net test --privileged=true --ip6 fd00:dead:beef::200 \
--dns fd00:dead:beef::200 --name bind9 --hostname bind9 \
--sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv6.conf.all.forwarding=1 \
-v /etc/bind9/named.conf:/etc/bind/named.conf resystit/bind9:latest
```
Remove the IPv4 addresses from the bind9 container and create a static route for the synthesized prefix with Tayga's IPv6 address as the next-hop:

```
sudo docker exec bind9 ip -6 route add $TAYGA_CONF_PREFIX via $TAYGA_IPV6_ADDR
IP=$(sudo docker exec bind9 ip addr list eth0 | grep "inet" | awk '$1 == "inet" {print $2}')
sudo docker exec bind9 ip addr del $IP dev eth0
```

# Test Client

Run a continer to test the DNS64/NAT64 deployment. This container is equivilent to [DIND](https://github.com/Mirantis/kubeadm-dind-cluster) master/node containers.
```
sudo docker run -it --dns fd00:dead:beef::200 --net test --name c1 \
--privileged=true --sysctl net.ipv6.conf.all.disable_ipv6=0 \
--sysctl net.ipv6.conf.all.forwarding=1 ubuntu /bin/bash
```

The above command will automaticly bring you into the test client container. Install packages used for testing:
```
apt-get update && apt-get install -y iproute2 curl
```

Remove the IPv4 address from the client and create a static route for the synthesized prefix with Tayga's IPv6 address as the next-hop:
```
export TAYGA_CONF_PREFIX=2001:db8:64:ff9b::/96
export TAYGA_IPV6_ADDR=fd00:dead:beef::100
IP=$(ip addr list eth0 | grep "inet" | awk '$1 == "inet" {print $2}')
ip addr del $IP dev eth0
ip -6 route add $TAYGA_CONF_PREFIX via $TAYGA_IPV6_ADDR
```

# Verify

From the test client container, `curl` an IPv4-only host on the Internet such as `hub.docker.com`. You should see curl connect using the synthetic IPv6 prefix and the hex encoded IPv4 address of `hub.docker.com`:
```
curl -6 -v hub.docker.com
* Rebuilt URL to: hub.docker.com/
*   Trying 2001:db8:64:ff9b::3449:f4a2...
* Connected to hub.docker.com (2001:db8:64:ff9b::3449:f4a2) port 80 (#0)
> GET / HTTP/1.1
> Host: hub.docker.com
> User-Agent: curl/7.47.0
> Accept: */*
>
< HTTP/1.1 301 Moved Permanently
< Content-length: 0
< Location: https://hub.docker.com/
< Connection: close
<
* Closing connection 0

```

`curl` a dual-stack host on the Internet such as `www.google.com`. Since Bind9 is configured to provide synthetic addresses for all hosts, curl will connect using the synthetic prefix and hex encoded IPv4 address of www.google.com instead of connecting over IPv6. Remove `exclude { any; };` from `named.conf` to change this behavior.
```
curl -6 -v www.google.com
* Rebuilt URL to: www.google.com/
*   Trying 2001:db8:64:ff9b::4a7d:1c63...
* Connected to www.google.com (2001:db8:64:ff9b::4a7d:1c63) port 80 (#0)
> GET / HTTP/1.1
> Host: www.google.com
> User-Agent: curl/7.47.0
> Accept: */*
>
< HTTP/1.1 200 OK
<SNIP>
```

Verify that you can download a file over IPv6:
```
curl -SLO6 https://github.com/containernetworking/plugins/releases/download/v0.6.0-rc1/cni-plugins-amd64-v0.6.0-rc1.tgz
```

# Troubleshooting

Make sure the bind9 container is running:
```
sudo docker ps
CONTAINER ID        IMAGE                                COMMAND                  CREATED             STATUS              PORTS                      NAMES
5d0d53f35460        resystit/bind9:latest                "named -c /etc/bin..."   4 seconds ago       Up 3 seconds        53/tcp                     bind9
```

Look at the bind9 container logs. Here is an example of bind9 starting up properly:
```
sudo docker logs 5d0d53f35460
31-Aug-2017 21:30:30.671 starting BIND 9.11.0-P5 <id:ad4fb79>
31-Aug-2017 21:30:30.671 running on Linux x86_64 4.4.0-66-generic #87-Ubuntu SMP Fri Mar 3 15:29:05 UTC 2017
31-Aug-2017 21:30:30.671 built with '--build=x86_64-alpine-linux-musl' '--host=x86_64-alpine-linux-musl' '--prefix=/usr' '--sysconfdir=/etc/bind' '--localstatedir=/var' '--with-openssl=/usr' '--enable-linux-caps' '--with-libxml2' '--enable-threads' '--enable-filter-aaaa' '--enable-ipv6' '--enable-shared' '--enable-static' '--with-libtool' '--with-randomdev=/dev/random' '--mandir=/usr/share/man' '--infodir=/usr/share/info' 'build_alias=x86_64-alpine-linux-musl' 'host_alias=x86_64-alpine-linux-musl' 'CC=gcc' 'CFLAGS=-Os -fomit-frame-pointer -D_GNU_SOURCE' 'LDFLAGS=-Wl,--as-needed' 'CPPFLAGS=-Os -fomit-frame-pointer'
31-Aug-2017 21:30:30.671 running as: named -c /etc/bind/named.conf -g -u named
31-Aug-2017 21:30:30.671 ----------------------------------------------------
<SNIP>
31-Aug-2017 21:30:30.722 all zones loaded
31-Aug-2017 21:30:30.723 running
```

Use `tcpdump` to verify that ICMP6 is flowing through the Docker bridge interface for the IPv6 test network:
```
sudo tcpdump -i br-a5f1befb883d icmp6
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on br-a5f1befb883d, link-type EN10MB (Ethernet), capture size 262144 bytes
21:03:12.607792 IP6 fd00:dead:beed::808:808 > fd00:dead:beef::2: ICMP6, echo reply, seq 11, length 64
<SNIP>
```

Do a ping sweep at different MTU sizes if you are having performance issues:
```
for size in {1460..1476..4}; do ping6 -s $size -c 1 -M do google.com; done
``

# References
[Oreilly DNS64](https://www.safaribooksonline.com/library/view/dns-and-bind/9781449308025/ch04.html)

[Tayga Documentation](http://www.litech.org/tayga/)

[Bind9 Container](https://hub.docker.com/r/resystit/bind9/)

[kubeadm-dind-cluster Project](https://hub.docker.com/r/resystit/bind9/)
