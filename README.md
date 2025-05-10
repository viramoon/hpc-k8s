# Kubernetes (K8s)
这是本科毕设项目
  本项目基于k8s v1.28.2开发，主要内容是添加了新的cpu manager策略HPC Policy，在static policy的基础上通过优化核心调度策略，配合自动化脚本实现了dpdk容器的高性能、高可用部署
  主要修改代码位于pkg/kubelet/cm/cpumanager路径下，所有的脚本和记录文件以及最终实验原始数据放在了AllTheFile目录下
