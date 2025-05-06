BESREFFORT_CGROUP="/sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice"  
BURSTABLE_CGROUP="/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice"

echo "=== CPU Manager BESREFFORT Policy Effects ==="  

for pod in $BESREFFORT_CGROUP/kubepods*.slice/; do  
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

echo "=== CPU Manager BURSTABLE Policy Effects ===" 
for pod in $BURSTABLE_CGROUP/kubepods*.slice/; do  
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