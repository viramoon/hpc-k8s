#!/bin/bash

kubectl delete -f ovs.yaml
kubectl delete -f testpmd.yaml
kubectl delete -f pktgen.yaml