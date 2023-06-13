# trex-benchmark

This repo contains an Openshift based NIC performance benchmark setup. It can be used in lieu of the Spirent testcenter for internal performance measurement and regression testing.
It uses [trex](https://trex-tgn.cisco.com/) for traffic generation and DPDK's testpmd app for forwarding on the Device Under Test (DUT).

### Dependencies

The test requires 2 SNOs with direct connections between 2 ports as illustrated below.

```
     ┌────────────────────────────┐                                 ┌────────────────────────────┐
     │ Openshift SNO / DU Profile │                                 │ Openshift SNO / DU Profile │
     │                            │                                 │                            │
     │     ┌──────────┐          ┌────┐                         ┌────┐        ┌──────────┐       │
     │     │          │          │ VF ├─────────────────────────┤ VF │        │          │       │
     │     │          │          └────┘                         └────┘        │          │       │
     │     │          │           │                                 │         │          │       │
     │     │          │           │                                 │         │          │       │
     │     │   TREX   │           │                                 │         │ TestPMD  │       │
     │     │          │           │                                 │         │          │       │
     │     │          │           │                                 │         │          │       │
     │     │          │           │                                 │         │          │       │
     │     │          │           │                                 │         │          │       │
     │     │          │          ┌────┐                         ┌────┐        │          │       │
     │     │          │          │ VF ├─────────────────────────┤ VF │        │          │       │
     │     └──────────┘          └────┘                         └────┘        └──────────┘       │
     │                            │                                 │                            │
     │                            │                                 │             DUT            │
     └────────────────────────────┘                                 └────────────────────────────┘
```
Both SNOs must be configured with the reference DU profile deployed with ZTP.  Specifically it expects the reference 2 sriov networks `sriov-nw-du-fh` and `sriov-nw-du-mh` from 2 VFs on 2 seperate ports.  The nodes must also have the Performance Profile configured.


# Test Setup

1. Apply the `testpmd-pod.yaml` on the DUT SNO and verify that testpmd started successuly

```bash
oc logs -n benchmark pod/testpmd
...

################# TESTPMD #################
Command: dpdk-testpmd -l 3,5,55,57 --socket-mem 0,1024 -n 4 --proc-type auto --file-prefix pg -a 0000:87:00.2 -a 0000:87:00.5 -- --forward-mode=mac --nb-cores 2 --nb-ports 2 --portmask 3 --coremask 0x200000000000020 --auto-start --rxq 2 --txq 2 --rxd 2048 --txd 2048 --max-pkt-len=1518
```
2. Apply the `trex-pod.yaml` on the Trex SNO and verify that the trex server started successuly

```bash
oc logs -n benchmark pod/trex
...

taskset -apc 3 14
################# TREX #################
Command: ./t-rex-64 -i --no-ofed-check --checksum-offload -v 4 --iom 0

Config file: /etc/trex_cfg.yaml

- port_limit: 2
  version: 2
  interfaces:
    - "0000:88:02.0"
    - "0000:88:0a.1"
  c: 2
  port_bandwidth_gb: 25
  port_info:
    - dest_mac        :   [0x60,0x0,0x0,0x0,0x0,0x1]
      src_mac         :   [0x50,0x0,0x0,0x0,0x0,0x1]
    - dest_mac        :   [0x60,0x0,0x0,0x0,0x0,0x2]
      src_mac         :   [0x50,0x0,0x0,0x0,0x0,0x2]
  platform:
    master_thread_id: 3
    latency_thread_id: 55
    dual_if:
      - socket: 1
        threads: [5,57]
trex-server is ready
```

## Staring traffic manually

Traffic can be manually started using the `trex-console`.  Here is a sample output for starting continuous traffic at 10% line rate with 256Bytes packets 

```bash
oc rsh -n benchmark pod/trex

sh-5.1# ./trex-console 

Using 'python3' as Python interpeter


Connecting to RPC server on localhost:4501                   [SUCCESS]


Connecting to publisher server on localhost:4500             [SUCCESS]


Acquiring ports [0, 1]:                                      [SUCCESS]


Server Info:

Server version:   v3.02 @ STL
Server mode:      Stateless
Server CPU:       14 x Intel(R) Xeon(R) Gold 6230R CPU @ 2.10GHz
Ports count:      2 x 25.0Gbps @ Ethernet Virtual Function 700 Series

-=TRex Console v3.0=-

Type 'help' or '?' for supported actions


trex> start -f stl/bench.py -m 10% --force -t size=256

Removing all streams from port(s) [0._, 1._]:                [SUCCESS]


Attaching 1 streams to port(s) [0._]:                        [SUCCESS]


Attaching 1 streams to port(s) [1._]:                        [SUCCESS]


Starting traffic on port(s) [0._, 1._]:                      [SUCCESS]

27.17 [ms]

trex>

```

Run the `tui` command to observe the live traffic stats

```bash
trex>tui
```

## Running an Non Drop Rate test


