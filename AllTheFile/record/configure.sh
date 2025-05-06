sudo docker run -it --privileged --cpuset-cpus="5-9" -v /dev/hugepages:/dev/hugepages -v /tmp/virtio/:/tmp/virtio/ testpmd
sudo docker run -it --privileged --cpuset-cpus="0-4" -v /dev/hugepages:/dev/hugepages -v /tmp/virtio/:/tmp/virtio/ pktgen
sudo docker run -it --privileged --cpuset-cpus="0-4" -v /dev/hugepages:/dev/hugepages -v /usr/local/var/run/openvswitch:/var/run/openvswitch pktgen
sudo docker run -it --privileged --cpuset-cpus="5-9" -v /dev/hugepages:/dev/hugepages -v /usr/local/var/run/openvswitch:/var/run/openvswitch testpmd
sudo ./dpdk-testpmd -n 2 -l 5-9 --socket-mem 1024 --vdev 'eth_vhost0,iface=/tmp/virtio/sock1' --vdev 'eth_vhost1,iface=/tmp/virtio/sock2' --file-prefix=testpmd --no-pci -- -i --rxq=1 --txq=1 --no-numa
sudo ./pktgen -l 0-4 -n 3 --socket-mem 1024 --vdev='virtio_user0,path=/tmp/virtio/sock1' --vdev='virtio_user1,path=/tmp/virtio/sock2' --file-prefix=pktgen --no-pci -- -P -m 1.0 -m 2.1
sudo ./dpdk-testpmd -n 2 -l 5-9 --socket-mem 1024 --vdev='net_virtio_user3,mac=00:00:00:00:00:03,path=/var/run/openvswitch/vhost-user3' --vdev='net_virtio_user4,mac=00:00:00:00:00:04,path=/var/run/openvswitch/vhost-user4' --file-prefix=testpmd --no-pci -- -i --rxq=1 --txq=1 --no-numa
sudo ./pktgen -l 0-4 -n 3 --socket-mem 1024 --vdev='net_virtio_user1,mac=00:00:00:00:00:01,path=/var/run/openvswitch/vhost-user1' --vdev='net_virtio_user2,mac=00:00:00:00:00:02,path=/var/run/openvswitch/vhost-user2' --file-prefix=pktgen --no-pci -- -T -m 1.0 -m 2.1

sudo cpupower frequency-set -g performance

sudo ./dpdk-testpmd -n 2 -l 5-9 --proc-type=auto -a 0000:06:00.0 -- -i --rxq=1 --txq=1 --no-numa --num-procs=2 --proc-id=

sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager

sudo virt-install \
  --name vm2 \
  --memory 6144 \
  --vcpus 6 \
  --disk path=/home/kagami/qemuimage/vm2.img,format=qcow2,bus=virtio \
  --os-variant ubuntu24.04 \
  --network bridge=vmbr0,model=virtio \
  --graphics vnc,listen=0.0.0.0 \
  --console pty,target_type=serial \
  --cdrom /home/kagami/qemuimage/ubuntu-24.04.1-live-server-amd64.iso 

sudo iptables -t nat -A POSTROUTING -s 192.168.11.0/24 -o wlo1 -j MASQUERADE
sudo sysctl -w net.ipv4.ip_forward=1

sudo vim /etc/netplan/00-installer-config.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp1s0:
      dhcp4: false
      dhcp6: false
      addresses:
        - 192.168.11.100/24
      routes:
        - to: default
          via: 192.168.11.1
      nameservers:
        addresses:
          - 192.168.11.1
          - 8.8.8.8
sudo netplan generate
sudo netplan apply

sudo vim /etc/apt/sources.list.d/ubuntu.sources

Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/ubuntu
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

# 默认注释了源码镜像以提高 apt update 速度，如有需要可自行取消注释
# Types: deb-src
# URIs: https://mirrors.tuna.tsinghua.edu.cn/ubuntu
# Suites: noble noble-updates noble-backports
# Components: main restricted universe multiverse
# Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

# 以下安全更新软件源包含了官方源与镜像站配置，如有需要可自行修改注释切换
Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

sudo swapoff -a
# 编辑 /etc/fstab，注释掉 swap 那一行
sudo vim /etc/fstab
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlaysudo nano /etc/fstab
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo apt-get update
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release 
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
#sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
wget https://mirrors.nju.edu.cn/docker-ce/linux/static/stable/x86_64/docker-20.10.24.tgz
tar -xf docker-20.10.24.tgz
cp docker/* /usr/bin
which docker
sudo docker --version
sudo usermod -aG docker $USER
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo systemctl daemon-reload
sudo systemctl restart docker
sudo systemctl enable docker
sudo docker pull swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/ubuntu:24.04
sudo docker tag  swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/ubuntu:24.04  docker.io/ubuntu:24.04
sudo docker rmi swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/ubuntu:24.04

curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

VER=0.3.4
sudo wget https://github.com/Mirantis/cri-dockerd/releases/download/v${VER}/cri-dockerd-${VER}.amd64.tgz
sudo tar xvf cri-dockerd-${VER}.amd64.tgz
sudo mv cri-dockerd/cri-dockerd /usr/local/bin/

sudo tee /etc/systemd/system/cri-docker.service << EOF
[Unit]
Description=CRI Interface for Docker Application Container Engine
Documentation=https://docs.mirantis.com
After=network-online.target firewalld.service docker.service
Wants=network-online.target
Requires=cri-docker.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/cri-dockerd --container-runtime-endpoint fd://
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/cri-docker.socket << EOF
[Unit]
Description=CRI Docker Socket for the API
PartOf=cri-docker.service

[Socket]
ListenStream=/var/run/cri-dockerd.sock
SocketMode=0660

SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cri-docker.service
sudo systemctl enable --now cri-docker.socket
sudo systemctl start cri-docker.service
sudo systemctl status cri-docker.service
sudo systemctl status cri-docker.socket

sudo docker pull registry.aliyuncs.com/google_containers/kube-apiserver:v1.28.2
sudo docker pull registry.aliyuncs.com/google_containers/kube-proxy:v1.28.2
sudo docker pull registry.aliyuncs.com/google_containers/kube-controller-manager:v1.28.2
sudo docker pull registry.aliyuncs.com/google_containers/kube-scheduler:v1.28.2
sudo docker pull registry.aliyuncs.com/google_containers/etcd:3.5.9-0
sudo docker pull registry.aliyuncs.com/google_containers/coredns:v1.10.1
sudo docker pull registry.aliyuncs.com/google_containers/pause:3.9

sudo docker tag registry.aliyuncs.com/google_containers/kube-apiserver:v1.28.2 registry.k8s.io/kube-apiserver:v1.28.2
sudo docker tag registry.aliyuncs.com/google_containers/kube-proxy:v1.28.2 registry.k8s.io/kube-proxy:v1.28.2
sudo docker tag registry.aliyuncs.com/google_containers/kube-controller-manager:v1.28.2 registry.k8s.io/kube-controller-manager:v1.28.2
sudo docker tag registry.aliyuncs.com/google_containers/kube-scheduler:v1.28.2 registry.k8s.io/kube-scheduler:v1.28.2
sudo docker tag registry.aliyuncs.com/google_containers/etcd:3.5.9-0 registry.k8s.io/etcd:3.5.9-0
sudo docker tag registry.aliyuncs.com/google_containers/coredns:v1.10.1 registry.k8s.io/coredns/coredns:v1.10.1
sudo docker tag registry.aliyuncs.com/google_containers/pause:3.9 registry.k8s.io/pause:3.9

sudo docker tag registry.k8s.io/kube-apiserver:v1.20.0 k8s.gcr.io/kube-apiserver:v1.20.0
sudo docker tag registry.k8s.io/kube-proxy:v1.20.0 k8s.gcr.io/kube-proxy:v1.20.0
sudo docker tag registry.k8s.io/kube-controller-manager:v1.20.0 k8s.gcr.io/kube-controller-manager:v1.20.0
sudo docker tag registry.k8s.io/kube-scheduler:v1.20.0 k8s.gcr.io/kube-scheduler:v1.20.0
sudo docker tag registry.k8s.io/etcd:3.4.13-0 k8s.gcr.io/etcd:3.4.13-0
sudo docker tag registry.k8s.io/coredns/coredns:v1.7.0 k8s.gcr.io/coredns:1.7.0
sudo docker tag registry.k8s.io/pause:3.2 k8s.gcr.io/pause:3.2

sudo docker rmi registry.aliyuncs.com/google_containers/kube-apiserver:v1.20.0
sudo docker rmi registry.aliyuncs.com/google_containers/kube-proxy:v1.20.0
sudo docker rmi registry.aliyuncs.com/google_containers/kube-controller-manager:v1.20.0
sudo docker rmi registry.aliyuncs.com/google_containers/kube-scheduler:v1.20.0
sudo docker rmi registry.aliyuncs.com/google_containers/etcd:3.4.13-0
sudo docker rmi registry.aliyuncs.com/google_containers/coredns:v1.7.0
sudo docker rmi registry.aliyuncs.com/google_containers/pause:3.2

sudo ip link add name vmbr0 type bridge
sudo ip link set vmbr0 up
sudo ip addr add 192.168.11.1/24 dev vmbr0
sudo ip addr add 192.168.11.2/24 dev vmbr0
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo iptables -t nat -A POSTROUTING -o wlo1 -j MASQUERADE

sudo vi /etc/docker/daemon.json  

{  
  "insecure-registries": ["192.168.10.150:30500"]  
}   
sudo systemctl daemon-reload  
sudo systemctl restart docker  

master node :
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --kubernetes-version v1.20.0 \
  --cri-socket unix:///var/run/cri-dockerd.sock
sudo kubeadm init --config ~/kubeadm-config.yaml
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
sudo mkdir -p /var/log/pods  
sudo chown -R root:root /var/log/pods  
sudo chmod 755 /var/log/pods


sudo docker pull swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/calico/cni:v3.28.2
sudo docker pull swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/calico/node:v3.28.2
sudo docker pull swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/calico/kube-controllers:v3.28.2
sudo docker tag swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/calico/cni:v3.28.2 docker.io/calico/cni:v3.28.2
sudo docker tag swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/calico/node:v3.28.2 docker.io/calico/node:v3.28.2
sudo docker tag swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/calico/kube-controllers:v3.28.2 docker.io/calico/kube-controllers:v3.28.2

curl https://calico-v3-25.netlify.app/archive/v3.20/manifests/calico-etcd.yaml -O
curl https://calico-v3-25.netlify.app/archive/v3.25/manifests/crds.yaml -O

sudo docker pull swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/flannel/flannel:v0.25.5
sudo docker tag swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/flannel/flannel:v0.25.5 docker.io/flannel/flannel:v0.25.5
sudo docker rmi swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/flannel/flannel:v0.25.5
sudo docker pull swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/flannel/flannel-cni-plugin:v1.5.1-flannel1
sudo docker tag swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/flannel/flannel-cni-plugin:v1.5.1-flannel1 docker.io/flannel/flannel-cni-plugin:v1.5.1-flannel1
sudo docker rmi swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/flannel/flannel-cni-plugin:v1.5.1-flannel1


kubectl apply -f calico-etcd.yaml --insecure-skip-tls-verify
kubectl get pods -n kube-system
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get componentstatuses

worker node :
mkdir -p $HOME/.kube
sudo scp kagami@192.168.11.1:/etc/kubernetes/admin.conf $HOME/.kube/config
sudo kubeadm join 192.168.10.150:6443 --token n7it65.0ow3ttv0m5io8qix --discovery-token-ca-cert-hash sha256:9b67263eaa48168df0b9f7d2ed7f79b8b2bd7fd7a1cb03cc97c1ad46d877f55e --cri-socket unix:///var/run/cri-dockerd.sock

kubeadm token create --print-join-command
