#!/usr/bin/env bash
SNABB_SEND_BLAST=true taskset -c 2 ./testsend.snabb Intel82599 $SNABB_PCI_INTEL1 0 source.pcap &
BLAST=$!

SNABB_RECV_SPINUP=2 SNABB_RECV_DURATION=5 taskset -c 4 ./testrecv.snabb Intel82599 $SNABB_PCI_INTEL0 0 > results.0 &
SNABB_RECV_SPINUP=2 SNABB_RECV_DURATION=5 taskset -c 6 ./testrecv.snabb Intel82599 $SNABB_PCI_INTEL0 1 > results.1

sleep 1
kill -9 $BLAST
test `cat results.0 | grep "^RXDGPC" | awk '{print $2}'` -gt 14000000
exit $?
