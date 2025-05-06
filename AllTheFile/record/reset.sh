sudo kubeadm reset -f --cri-socket unix:///var/run/cri-dockerd.sock
sudo rm -rf ~/.kube && echo "rm complete\n"
sudo rm -rf /etc/cni
sudo rm -rf /var/lib/cni/
sudo ip link delete flannel.1
sudo ip link delete cni0
sudo systemctl restart docker
sudo systemctl restart cri-docker
sudo systemctl restart kubelet
sleep 2 && echo "sleep complete\n"
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --kubernetes-version v1.28.2 \
  --apiserver-advertise-address=192.168.10.150 \
  --cri-socket unix:///var/run/cri-dockerd.sock -v=9
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
