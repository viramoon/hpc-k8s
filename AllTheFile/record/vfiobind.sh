sudo modprobe vfio-pci
sudo modprobe vhost
sudo modprobe openvswitch
sudo modprobe vhost_net
sudo modprobe vhost_user
sudo ifconfig enp6s0 down
sudo dpdk-devbind.py -u 06:00.0
sudo dpdk-devbind.py -b vfio-pci 06:00.0
sudo dpdk-devbind.py --status
