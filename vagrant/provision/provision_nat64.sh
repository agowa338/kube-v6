#!/bin/bash
#
# Author: Pierre Pfister <ppfister@cisco.com>
#
# Largely inspired from contiv-VPP vagrant file.
#

set -ex
echo Args passed: [[ $@ ]]

nat64_prefix=$K8S_NAT64_PREFIX

echo "Installing required packages"
sudo apt-get install -y build-essential linux-headers-$(uname -r) dkms \
	gcc make pkg-config libnl-genl-3-dev autoconf \
		bind9 iptables-dev tayga

echo "Configuring systemd unit"
sudo tee /etc/systemd/system/nat64.service << EOF
[Unit]
Description=Tayga NAT64
After=network.target
[Service]
ExecStart=/usr/sbin/tayga --nodetach -d
[Install]
WantedBy=default.target
EOF

echo "Configuring bind"
cat | sudo tee /etc/bind/named.conf.options << EOF
options {
  directory "/var/cache/bind";
  //dnssec-validation auto;
  auth-nxdomain no;
  listen-on-v6 { any; };
	forwarders {
	  8.8.8.8;
	};
	allow-query { any; };
	# Add prefix for Jool's pool6
	dns64 $nat64_prefix/96 {
	  exclude { any; };
	};
};
EOF

sudo service bind9 restart
systemctl status bind9


cat | sudo tee /etc/tayga.conf << EOF
tun-device nat64
ipv4-addr 192.168.255.1
ipv6-addr 2001:db8::2
prefix 64:ff9b::/96
dynamic-pool 192.168.255.0/24
data-dir /var/spool/tayga
EOF

sudo tayga --mktun                                # Create virtual tunnel interface
sudo ip link set nat64 up                         # Activate tunnel interface

sudo ip addr add 192.168.255.1 dev nat64          # Give our selve an address within the ipv4 address pool for iptables
sudo ip addr add 2001:db8::1/126 dev nat64        # Transfer network between us and tayga
sudo ip route add 192.168.255.0/24 dev nat64      # the replacement address pool tayga uses as source address
sudo ip route add 64:ff9b::/96 via 2001:db8::2    # Route 64:ff9b::/96 via tayga

sudo systemctl start nat64                        # start tayga

# Statefull NAT ipv4 requests from NAT64 interface onto public facing interface
sudo iptables -t nat -A POSTROUTING -s 192.168.255.0/24 -j SNAT --to-source "172.17.0.1"
sudo iptables -t filter -A FORWARD -s 192.168.255.0/24 -i nat64 -j ACCEPT
sudo iptables -t filter -A FORWARD -d 192.168.255.0/24 -o nat64 -j ACCEPT
