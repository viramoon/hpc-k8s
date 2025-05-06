from testpmd import logInit, parseCores, expectStream

if __name__ == "__main__":

    coreParseScripts = "/etc/scripts/ParseCoreIndex.sh"
    RecordFile = "/var/log/pktgenRecord.log"
    DataFile = "/var/log/pktgenData.log"

    logger = logInit(RecordFile, "pktgen")
    output = parseCores(coreParseScripts, logger)
    cores= [int(x.strip()) for x in output.split(',')]

    if not cores:
        logger.error("parse core index failed")
        exit(1)

    if len(cores) < 3:
        logger.error("number of cores is too small")
        exit(1)

    hugeMemSize = 1024

    cmd = (f"pktgen -n 2 -l {output} --socket-mem {hugeMemSize} "  
        "--vdev='net_virtio_user1,mac=00:00:00:00:00:01,path=/var/run/openvswitch/vhost-user1' "
        "--vdev='net_virtio_user3,mac=00:00:00:00:00:03,path=/var/run/openvswitch/vhost-user3' "
        f"--file-prefix=pktgen --no-pci -- --txd=5120 --rxd=1024 -T -m {cores[-1]}.0 -m {cores[-2]}.1 ") 
    
    logger.debug(cmd)
    logFile = open(DataFile, "a")
    behavior = ["enable all latency","set 0 dst mac 00:00:00:00:00:02","set 1 dst mac 00:00:00:00:00:04","set 1 rate 50","set 0 rate 50","start all", "page main"]
    expect = ["Pktgen:/>", "Pktgen:/>", "Pktgen:/>", "Pktgen:/>", "Pktgen:/>", "Pktgen:/>", "Pktgen:/>", "Pktgen:/>"]

    stream = expectStream("pktgen", cmd, log = logFile, logger = logger, behavior = behavior, expect = expect)
    logger.debug("pexpect stream of pktgen created")
    stream.start()