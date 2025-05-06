#!/bin/bash
set -x
if [$# -ne 2]; then
        exit 1;
fi

rm /usr/local/etc/openvswitch/*
rm /usr/local/var/run/openvswitch/*
rm /usr/local/var/log/openvswitch/ovs-vswitchd.log
mkdir -p /usr/local/etc/openvswitch
mkdir -p /usr/local/var/run/openvswitch
mkdir -p /usr/local/var/log/openvswitch
ovsdb-tool create /usr/local/etc/openvswitch/conf.db /usr/local/share/openvswitch/vswitch.ovsschema
ovsdb-server --remote=punix:/usr/local/var/run/openvswitch/db.sock \
        --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
        --pidfile --detach
ovs-vsctl --no-wait init
ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true \
        other_config:dpdk-lcore-mask=$1 other_config:dpdk-socket-mem="1024" other_config:dpdk-huge-dir="/dev/hugepages"
ovs-vswitchd unix:/usr/local/var/run/openvswitch/db.sock --log-file=/usr/local/var/log/openvswitch/ovs-vswitchd.log \
        --pidfile --detach
ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=$2
ovs-vsctl add-br br0 -- set bridge br0 datapath_type=netdev
ovs-vsctl add-port br0 vhost-user1 -- set Interface vhost-user1 type=dpdkvhostuser options:rxq_size=5120 options:txq_size=1024
ovs-vsctl add-port br0 vhost-user2 -- set Interface vhost-user2 type=dpdkvhostuser options:rxq_size=10240 options:txq_size=1024
ovs-vsctl add-port br0 vhost-user3 -- set Interface vhost-user3 type=dpdkvhostuser options:rxq_size=5120 options:txq_size=1024
ovs-vsctl add-port br0 vhost-user4 -- set Interface vhost-user4 type=dpdkvhostuser options:rxq_size=10240 options:txq_size=1024
ovs-ofctl del-flows br0
ovs-ofctl add-flow br0 in_port=1,action=output:2
ovs-ofctl add-flow br0 in_port=2,action=output:1
ovs-ofctl add-flow br0 in_port=3,action=output:4
ovs-ofctl add-flow br0 in_port=4,action=output:3
ovs-ofctl dump-flows br0
ls -la /usr/local/var/run/openvswitch | grep vhost-user