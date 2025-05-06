from testpmd import logInit, parseCores, commandRun
import time

if __name__ == "__main__" :

    coreParseScripts = "/etc/scripts/ParseCoreIndex.sh"
    RecordFile = "/var/log/ovsRecord.log"
    DataFile = "/var/log/ovsData.log"
    startOvsScripts = "/etc/scripts/startovs.sh"

    logger = logInit(RecordFile, "ovs")
    output = parseCores(coreParseScripts, logger)
    cores= [int(x.strip()) for x in output.split(',')]

    if not cores:
        logger.error("parse core index failed")
        exit(1)

    lcore_mask = 0
    pmd_mask = 0

    for i in cores:
        num = 1 << i
        if lcore_mask == 0:
            lcore_mask += num
        else:
            pmd_mask += num

    

    cmd = (f"bash {startOvsScripts} {hex(lcore_mask)} {hex(pmd_mask)}")
    logger.debug(cmd)
    showStats = "ovs-appctl dpif-netdev/pmd-rxq-show&&ovs-appctl dpif-netdev/pmd-perf-show&&ovs-appctl dpif-netdev/pmd-stats-show"
    strs = showStats.split("&&")
    result = commandRun(cmd, logger)
    time.sleep(2)
    logger.info(result.stdout)
    for i in range(6) :
        time.sleep(60)
        for str in strs:
            result = commandRun(str, logger)
            if result:
                logger.info(result.stdout)