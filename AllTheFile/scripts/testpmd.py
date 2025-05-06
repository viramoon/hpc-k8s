import subprocess
import pexpect
import logging
import os
import sys
import time
from datetime import datetime

def logInit(FileName = None, loggerName = None):
    logger = logging.getLogger(loggerName)
    LOG_FORMAT = "%(asctime)s - %(levelname)s - %(message)s"
    if loggerName:
        LOG_FORMAT = "%(name)s - " + LOG_FORMAT
    logging.basicConfig(filename=FileName, level=logging.DEBUG, format=LOG_FORMAT)
    logger.debug("logger start successfully")
    return logger

def commandRun(command, logger):
    logger.debug(f"call command: \"{command}\"")
    try:
        result = subprocess.run(command, shell = True, check = True, text = True, stdout = subprocess.PIPE, stderr = subprocess.PIPE)
    except Exception as e:
        logger.error(f"command: \"{command}\" error, error info:{e}")
        return None
    return result


def parseCores(pathForScript, logger):
    if not logger:
        print("logger not exist")
        return None
    if not os.path.exists(pathForScript):
        logger.error(f"path:{pathForScript} not exists")
        return None
    logger.debug(f"{pathForScript} exists")
    result = commandRun(f"bash {pathForScript}", logger)
    if not result:
        logger.error(f"script {pathForScript} went wrong")
        return None
    if result.stderr :
        logger.error(f"script {pathForScript} return stderr:{result.stderr}")
        return None
    output = result.stdout 
    logger.debug(f"parsed cpu cores: {output}")
    return output
    
class expectStream:

    def __init__(self, name, cmd, logger = None, log = sys.stdout, interval = 60, totalDuration = 300, behavior = None, expect = None, timeout = 30):
        self.name = name
        self.cmd = cmd
        self.log = log
        self.interval = interval
        self.totalDuration = totalDuration
        self.behavior = behavior
        self.expect = expect
        self.timeout = timeout
        self.logger = logger

    def validCheck(self):
        if not self.logger:
            print("No looger passed to pexpectStream")
            return False
        if not self.name:
            self.logger.error(f"pexpect's name is None")
            return False
        if not self.cmd:
            self.logger.error(f"pexpect's cmd is None")
            return False
        if not self.behavior:
            self.logger.error(f"pexpect's behavior is None")
            return False
        if not self.expect:
            self.logger.error(f"pexpect's expect is None")
            return False
        if len(self.behavior) != len(self.expect) - 1:
            self.logger.error(f"pexpect's bahaviour and expect's len is not equal")
            return False
        if len(self.behavior) <= 1:
            self.logger.error(f"pexpect's bahaviour is too short")
            return False
        return True

    def judge(self, index):
            id = self.child.expect([self.expect[index], pexpect.TIMEOUT, pexpect.EOF], timeout=self.timeout)
            if id == 0:
                self.logger.debug("running successfully")
            elif id == 1:
                self.logger.error("started faild by timeout")
                return None
            elif id == 2:
                self.logger.error("started faild by EOF")
                return None
            return True
    def process(self, index):
        strs = self.behavior[index].split("&&")
        for str in strs:
            self.child.sendline(str)
            if not self.judge(-1):
                return None
    
    def start(self):
        if not self.validCheck():
            print.error("pexpect valid check faild")
            return None
        try:
            self.child = pexpect.spawn(self.cmd, logfile = self.log, encoding='utf-8')
            self.logger.info("------------pexpect stream started------------------")
            start_time = datetime.now()
            for index in range(len(self.behavior) - 1):
                if not self.judge(index):
                    return None
                self.child.sendline(self.behavior[index])

            if not self.judge(-2):
                return None
            
            self.logger.debug("loop will start")
            while True:
                self.logger.debug("loop-----")
                sleepTime = self.interval
                self.process(-1)
                elapsed = (datetime.now() - start_time).total_seconds()
                if elapsed >= self.totalDuration:
                    break
                elif self.totalDuration - elapsed <=  self.interval:
                    sleepTime = self.totalDuration - elapsed
                time.sleep(sleepTime)

            self.child.sendline("quit")
            self.child.expect(pexpect.EOF)

        except Exception as e:
            self.logger.error(f"pexpect stream return error:{e}")


if __name__ == "__main__" :

    coreParseScripts = "/etc/scripts/ParseCoreIndex.sh"
    RecordFile = "/var/log/testpmdRecord.log"
    DataFile = "/var/log/testpmdData.log"

    logger = logInit(RecordFile, "testpmd")

    output = parseCores(coreParseScripts, logger)
    cores= [int(x.strip()) for x in output.split(',')]

    if not cores:
        logger.error("parse core index failed")
        exit(1)

    hugeMemSize = 1024

    cmd = (f"dpdk-testpmd -n 2 -l {output} --socket-mem {hugeMemSize} "  
        "--vdev='net_virtio_user2,mac=00:00:00:00:00:02,path=/var/run/openvswitch/vhost-user2' "
        "--vdev='net_virtio_user4,mac=00:00:00:00:00:04,path=/var/run/openvswitch/vhost-user4' "  
        f"--file-prefix=testpmd --no-pci -- -i --txd=10240 --rxd=1024 --txq=1 --rxq=1 --nb-cores={len(cores)-1} --no-numa") 
    
    logFile = open(DataFile, "a")
    behavior = ["start", "show config rxtx&&show fwd stats all"]
    expect = ["testpmd>", "testpmd>", "testpmd>"]

    stream = expectStream("testpmd", cmd, log = logFile, logger = logger, behavior = behavior, expect = expect)
    logger.debug("pexpect stream of testpmd created")
    stream.start()
