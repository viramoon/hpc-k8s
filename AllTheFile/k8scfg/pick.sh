#!/bin/bash
target_file="/home/kagami/data"
testpmd_data="/var/log/dpdktest/testpmdData.log"
pktgen_data="/var/log/dpdktest/pktgenData.log"
ovs_data="/var/log/dpdktest/ovsRecord.log"
perf_data="/var/log/dpdktest/perf_data.log"
flag="start test round"
perfEvent="dTLB-load-misses,dTLB-loads,mem_load_retired.l1_hit,mem_load_retired.l1_miss,branch-instructions,branch-misses"
pids=()

clear_log() {
    echo "" > $testpmd_data
    echo "" > $pktgen_data
    echo "" > $ovs_data
    echo "" > $perf_data
}

is_process_continue() {
    if [[ $(ps aux | grep "testpmd" | wc -l) -ne 1 ]]; then
        return 0
    elif [[ $(ps aux | grep "pktgen" | wc -l) -ne 1 ]]; then
        return 0
    elif [[ $(ps aux | grep "ovs" | wc -l) -ne 1 ]]; then
        return 0
    fi
    return 1
}

testpmd() {
    grep "testpmd> quit" -A 20 $testpmd_data
    return 0
}

pktgen() {
    grep -E "Port:Flags|Count/Percent|Cycles/Average(us)" $pktgen_data
    return 0
}
ovs() {
    grep -E "pmd thread numa_id|busy iterations|Rx packets|Tx packets" $ovs_data | tail -n 70
    return 0
}

pause() {
    while is_process_continue; do
        sleep 5
    done
}

startPerf() {
    pids+=($(ps aux | grep dpdk-testpmd | grep -v grep | awk '{print $2}'))
    pids+=($(ps aux | grep /usr/local/bin/pktgen | grep -v grep | awk '{print $2}'))
    pids+=($(ps aux | grep ovs-vswitchd | grep -v grep | awk '{print $2}'))
    echo ${pids[0]}
    echo ${pids[1]}
    echo ${pids[2]}
    if [[ $# -ne 1 ]]; then
        echo "startPerf input error"
        exit 1
    fi
    if [[ $1 -eq "1" ]]; then
        for (( i=0;i<=2;i++ )); do
            sudo perf stat -p ${pids[i]} -e $perfEvent 2>&1 &
            pids+=($!)
        done
    fi
    echo ${pids[3]}
    echo ${pids[4]}
    echo ${pids[5]}
    sleep 240
    kill -2 ${pids[3]}
    sleep 1
    kill -2 ${pids[4]}
    sleep 1
    kill -2 ${pids[5]}
    return 0
}

recordPerf() {
    grep -E "% of all|mem_load" $perf_data
    return 0
}

recordData() {
    echo "------------------------------testpmd-------------------------------"
    testpmd
    echo "------------------------------pktgen--------------------------------"
    pktgen
    echo "-------------------------------ovs----------------------------------"
    ovs
    echo "-------------------------------perf----------------------------------"
    recordPerf
}


pick() {
    echo "" > "$target_file.tmp"
    awk -v flag="$flag" '
    BEGIN{count = 0}
    {
        if (index($0, flag) > 0) {
            count++
        }
        print
    }
    END{
        print "-------------- ", flag, count, " ----------------------"
    }' $target_file >> "$target_file.tmp"
    recordData >> "$target_file.tmp"
    mv "$target_file.tmp" $target_file
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

kubectl delete -f ovs.yaml
kubectl delete -f testpmd.yaml
kubectl delete -f pktgen.yaml
clear_log
kubectl apply -f ovs.yaml
sleep 1
kubectl apply -f testpmd.yaml
sleep 1
kubectl apply -f pktgen.yaml
sleep 5
startPerf 1 > $perf_data
pause
pick