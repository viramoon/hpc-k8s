#!/bin/bash  

 
POD_CGROUP="/sys/fs/cgroup/kubepods.slice"  

echo "=== CPU Manager Static Policy Effects ==="  
 
for pod in $POD_CGROUP/kubepods-pod*.slice/; do  
    if [ -d "$pod" ]; then  
        echo "Pod: $(basename $pod)"  
        echo "CPUSet: $(cat $pod/cpuset.cpus)"  
        echo "Effective CPUs: $(cat $pod/cpuset.cpus.effective)"  
         
        # 检查容器  
        for container in $pod/*/; do  
            if [ -d "$container" ]; then  
                echo "  Container: $(basename $container)"  
                echo "  CPUSet: $(cat $container/cpuset.cpus.effective)"  
            fi  
        done  
    fi  
done  
