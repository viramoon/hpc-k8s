sudo rm /usr/local/etc/openvswitch/*
sudo rm /usr/local/var/run/openvswitch/*
sudo rm /usr/local/var/log/openvswitch/ovs-vswitchd.log
sudo mkdir -p /usr/local/etc/openvswitch && \
sudo mkdir -p /usr/local/var/run/openvswitch && \
sudo mkdir -p /usr/local/var/log/openvswitch && \
sudo ./ovsdb/ovsdb-tool create /usr/local/etc/openvswitch/conf.db ./vswitchd/vswitch.ovsschema && \
sudo ./ovsdb/ovsdb-server --remote=punix:/usr/local/var/run/openvswitch/db.sock \
        --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
        --pidfile --detach && \
sudo ./utilities/ovs-vsctl --no-wait init && \
sudo ./utilities/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true \
        other_config:dpdk-lcore-mask=0xc00 other_config:dpdk-socket-mem="1024" other_config:dpdk-huge-dir="/dev/hugepages" && \
sudo ./vswitchd/ovs-vswitchd unix:/usr/local/var/run/openvswitch/db.sock --log-file=/usr/local/var/log/openvswitch/ovs-vswitchd.log \
        --pidfile --detach && \
sudo ./utilities/ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=0xf000 && \
sudo ./utilities/ovs-vsctl add-br br0 -- set bridge br0 datapath_type=netdev && \
sudo ./utilities/ovs-vsctl add-port br0 vhost-user1 -- set Interface vhost-user1 type=dpdkvhostuser && \
sudo ./utilities/ovs-vsctl add-port br0 vhost-user2 -- set Interface vhost-user2 type=dpdkvhostuser && \
sudo ./utilities/ovs-vsctl add-port br0 vhost-user3 -- set Interface vhost-user3 type=dpdkvhostuser && \
sudo ./utilities/ovs-vsctl add-port br0 vhost-user4 -- set Interface vhost-user4 type=dpdkvhostuser && \
sudo ./utilities/ovs-ofctl del-flows br0 && \
sudo ./utilities/ovs-ofctl add-flow br0 in_port=2,dl_type=0x800,idle_timeout=0,action=output:3 && \
sudo ./utilities/ovs-ofctl add-flow br0 in_port=3,dl_type=0x800,idle_timeout=0,action=output:2 && \
sudo ./utilities/ovs-ofctl add-flow br0 in_port=1,dl_type=0x800,idle_timeout=0,action=output:4 && \
sudo ./utilities/ovs-ofctl add-flow br0 in_port=4,dl_type=0x800,idle_timeout=0,action=output:1 && \
sudo ./utilities/ovs-ofctl dump-flows br0 && \
ls -la /usr/local/var/run/openvswitch | grep vhost-user