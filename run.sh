#!/bin/bash

# env vars:
#   RING_SIZE (default 2048)
#   SOCKET_MEM (default autoconfigured)
#   MEMORY_CHANNELS (default 4)
#   FORWARD_MODE (default "mac")
#   PEER_A_MAC (no default, required if FORWARD_MODE=="mac", error)
#   PEER_B_MAC (no default, required if FORWARD_MODE=="mac", error)
#   SRIOV_ID_A (no default, error)
#   SRIOV_ID_B (no default, error)
#   MTU (default 1518)

function set_fwd_thread_sched () {
  sleep 2
  while ! pidof dpdk-testpmd >&/dev/null
  do
    sleep 1
  done

  pid=$(pidof dpdk-testpmd)

  for tid in $(ps -T -p ${pid} | grep lcore-worker | awk '{print $2}')
  do
    echo "chrt --fifo -p 1 ${tid}"
    chrt --fifo -p 1 ${tid}
  done
}

function wait_for_trex_server_ready () {
  count=60
  num_ports=0
  while [ ${count} -gt 0 -a ${num_ports} -lt 2 ]; do
    sleep 1
    num_ports=`netstat -tln | grep -E :4500\|:4501 | wc -l`
    ((count--))
  done
  if [ ${num_ports} -eq 2 ]; then
    echo "trex-server is ready"
  else
    echo "ERROR: trex-server could not start properly.  Check \'tmux attach -t trex\' and/or \'cat /tmp/trex.server.out\'"
    exit 1
  fi
}

function set_allowed_hk_affinity () {
  local cpuset=${1}
  local tasksetOutput
  tasksetOutput="$(taskset -apc "$cpuset" $$ 2>&1)"
  if [[ $? -ne 0 ]]; then
    echo "ERROR: $tasksetOutput"
    exit 1
  else
    echo "taskset -apc "$cpuset" $$"
  fi
}

function get_allowd_fwd () {
  local -n cpu_hk=${1}
  local -n cpuset=${2}

  cpu_fwd=(${cpuset[@]})
  length=${#cpu_fwd[@]}
  for (( i=0; i<${length}; i++ ))
  do
    if [[ ${cpu_fwd[$i]} == ${cpu_hk[0]} || ${cpu_fwd[$i]} == ${cpu_hk[1]} ]]
    then
      unset cpu_fwd[$i]
    fi
  done
  echo "${cpu_fwd[*]}"
}

function get_allowed_siblings () {
  local -n cpuset=${1}

  for cpuid in "${cpuset[@]}"; do
    sib=$(cat "/sys/devices/system/cpu/cpu${cpuid}/topology/thread_siblings_list")
    siblings="${siblings} ${sib}"
  done
  siblings=( `for i in ${siblings[@]}; do echo $i; done | sort -nu` )

  echo "${siblings[*]}"

}

function get_cpus_allowed() {
    echo "$(grep Cpus_allowed_list /proc/self/status | cut -f 2)"
}

function expand_number_list() {
    # expand a list of numbers to no longer include a range
    # ie. "1-3,5" becomes "1,2,3,5"
    local range=${1}
    local list=""
    local items=""
    local item=""
    for items in $(echo "${range}" | sed -e "s/,/ /g"); do
	if echo ${items} | grep -q -- "-"; then
	    items=$(echo "${items}" | sed -e "s/-/ /")
	    items=$(seq ${items})
	fi
	for item in ${items}; do
	    list="${list},$item"
	done
    done
    list=$(echo "${list}" | sed -e "s/^,//")
    echo "${list}"
}

function separate_comma_list() {
    echo "${1}" | sed -e "s/,/ /g"
}

echo -e "\nStarting ${0}\n"

echo "############### Logging ENV ###############"
env
echo -e "###########################################\n"

echo "############### IP Address ################"
ip address
echo -e "###########################################\n"

if [ -z "${SRIOV_ID_A}" -o -z "${SRIOV_ID_B}" ]; then
    echo "ERROR: You must specify SRIOV_ID_A and SRIOV_ID_B environment variables"
    exit 1
fi

# find the SRIOV devices
# OCP creates environment variables which contain information about the devices
# example:
#   PCIDEVICE_OPENSHIFT_IO_MELLANOXA=0000:86:00.2
#   PCIDEVICE_OPENSHIFT_IO_MELLANOXB=0000:86:01.4

DEVICE_A=$(env | grep -w "PCIDEVICE_OPENSHIFT_IO_${SRIOV_ID_A}" | cut -f2 -d'=')
DEVICE_B=$(env | grep -w "PCIDEVICE_OPENSHIFT_IO_${SRIOV_ID_B}" | cut -f2 -d'=')

echo "################# DEVICES #################"
echo "DEVICE_A=${DEVICE_A}"
echo "DEVICE_B=${DEVICE_B}"
echo -e "###########################################\n"

if [ -z "${DEVICE_A}" -o -z "${DEVICE_B}" ]; then
    echo "ERROR: Could not find DEVICE_A and/or DEVICE_B"
    exit 1
fi

function get_vf_driver() {
    ls /sys/bus/pci/devices/${1}/driver/module/drivers | sed -n -r 's/.*:(.+)/\1/p'
}

DEVICE_A_VF_DRIVER=$(get_vf_driver ${DEVICE_A})
DEVICE_B_VF_DRIVER=$(get_vf_driver ${DEVICE_B})

echo "################ VF DRIVER ################"
echo "DEVICE_A_VF_DRIVER=${DEVICE_A_VF_DRIVER}"
echo "DEVICE_B_VF_DRIVER=${DEVICE_B_VF_DRIVER}"
echo -e "###########################################\n"

if [ -z "${DEVICE_A_VF_DRIVER}" -o -z "${DEVICE_B_VF_DRIVER}" ]; then
    echo "ERROR: Could not VF driver for DEVICE_A and/or DEVICE_B"
    exit 1
fi

CPUS_ALLOWED=$(get_cpus_allowed)
CPUS_ALLOWED_EXPANDED=$(expand_number_list "${CPUS_ALLOWED}")
CPUS_ALLOWED_SEPARATED=$(separate_comma_list "${CPUS_ALLOWED_EXPANDED}")
CPUS_ALLOWED_ARRAY=(${CPUS_ALLOWED_SEPARATED})
CPUS_ALLOWED_SIBLINGS=( $(get_allowed_siblings CPUS_ALLOWED_ARRAY) )
IFS=',' read -r -a CPUS_ALLOWED_HK <<< "${CPUS_ALLOWED_SIBLINGS[0]}"
CPUS_ALLOWED_FWD=( $(get_allowd_fwd CPUS_ALLOWED_HK CPUS_ALLOWED_ARRAY) )

if [ -z "${RING_SIZE}" ]; then
    RING_SIZE=2048
fi

NODE_LIST="unknown"

if [ -z "${SOCKET_MEM}" ]; then
    # automatically determine what NUMA nodes need memory allocated
    if pushd /sys/devices/system/node > /dev/null; then
	SOCKET_MEM=""

	for node in $(ls -1d node*); do
	    NODE_NUM=$(echo ${node} | sed -e "s/node//")
	    if pushd $node > /dev/null; then
		NODE_CPU_PRESENT=0

		for cpu in ${CPUS_ALLOWED_SEPARATED}; do
		    if [ -d "cpu${cpu}" ]; then
			NODE_CPU_PRESENT=1
		    fi
		done

		if [ "${NODE_CPU_PRESENT}" == "1" ]; then
		    SOCKET_MEM+="1024,"
		    NODE_LIST="${NODE_NUM},"
		else
		    SOCKET_MEM+="0,"
		fi

		popd > /dev/null
	    fi
	done

	SOCKET_MEM=$(echo "${SOCKET_MEM}" | sed -e "s/,$//")
	NODE_LIST=$(echo "${NODE_LIST}" | sed -e "s/,$//")

	popd > /dev/null
    fi

    # if we didn't figure anything out just go with a safe default and
    # see if it works
    if [ -z "${SOCKET_MEM}" ]; then
	SOCKET_MEM="1024,1024"
    fi
fi

if [ -z "${MEMORY_CHANNELS}" ]; then
    MEMORY_CHANNELS="4"
fi

if [ -z "${MTU}" ]; then
    MTU="1518"
fi



echo "################# VALUES ##################"
echo "CPUS_ALLOWED=${CPUS_ALLOWED}"
echo "CPUS_ALLOWED_EXPANDED=${CPUS_ALLOWED_EXPANDED}"
echo "CPUS_ALLOWED_SEPARATED=${CPUS_ALLOWED_SEPARATED}"
echo "CPUS_ALLOWED_SIBLINGS=${CPUS_ALLOWED_SIBLINGS[@]}"
echo "CPUS_ALLOWED_HK=${CPUS_ALLOWED_HK[@]}"
echo "CPUS_ALLOWED_FWD=${CPUS_ALLOWED_FWD[@]}"
echo "CPUS_ALLOWED_FWD_MASK=${CPUS_ALLOWED_FWD_MASK}"
echo "NODE_LIST=${NODE_LIST}"
echo "RING_SIZE=${RING_SIZE}"
echo "SOCKET_MEM=${SOCKET_MEM}"
echo "MEMORY_CHANNELS=${MEMORY_CHANNELS}"
echo "PEER_A_MAC=${PEER_A_MAC}"
echo "PEER_B_MAC=${PEER_B_MAC}"
echo "MTU=${MTU}"
echo -e "###########################################\n"

if [ ${#CPUS_ALLOWED_ARRAY[@]} -ne 16 ]; then
    echo "ERROR: This test needs 16 CPUs!"
    exit 1
fi

set_allowed_hk_affinity ${CPUS_ALLOWED_HK}

cat <<- END_OF_TREX_CONFIG > /etc/trex_cfg.yaml
- port_limit: 2
  version: 2
  interfaces:
    - "${DEVICE_A}"
    - "${DEVICE_B}"
  c: 14
  port_bandwidth_gb: ${PORT_BANDWIDTH_GB}
  port_info:
    - dest_mac        :   [0x60,0x0,0x0,0x0,0x0,0x1]
      src_mac         :   [0x50,0x0,0x0,0x0,0x0,0x1]
    - dest_mac        :   [0x60,0x0,0x0,0x0,0x0,0x2]
      src_mac         :   [0x50,0x0,0x0,0x0,0x0,0x2]
  platform:
    master_thread_id: ${CPUS_ALLOWED_HK[0]}
    latency_thread_id: ${CPUS_ALLOWED_HK[1]}
    dual_if:
      - socket: 1
        threads: [$(echo "$(IFS=,; echo "${CPUS_ALLOWED_FWD[*]}")")]
END_OF_TREX_CONFIG

EXTRA_TREX_ARGS=""
if [ ${MTU} -gt 2048 ]; then
    MBUF_SIZE=16384
    MBUFS=27242
    EXTRA_TREX_ARGS+=" --mbuf-size=${MBUF_SIZE} --total-num-mbufs=${MBUFS}"
fi

TREX_CMD="./t-rex-64 -i --no-ofed-check --checksum-offload -v 4 --iom 0"
#TREX_CMD=$(echo "${TREX_CMD}" | sed -e "s/\s\+/ /g")

echo "################# TREX #################"
echo -e "Command: ${TREX_CMD}\n"

echo -e "Config file: /etc/trex_cfg.yaml\n"
cat /etc/trex_cfg.yaml

# start testpmd
tmux new-session -d -n server -s trex "bash -c '${TREX_CMD}| tee /tmp/trex.server.out'; touch /tmp/trex-stopped; sleep infinity"

wait_for_trex_server_ready

function sigtermhandler() {
    echo "Caught SIGTERM"
    local PID=$(pgrep -f "coreutils.*sleep")
    if [ -n "${PID}" ]; then
	echo "Killing sleep with PID=${PID}"
	kill ${PID}
    else
	echo "Could not find PID for sleep"
    fi
}

trap sigtermhandler TERM


# block, waiting for a signal telling me to stop.  backgrounding and
# using wait allows for signal handling to occur
sleep infinity &
wait $!

# kill trex
pkill _t-rex-64

# spin waiting for trex to exit
while [ ! -e "/tmp/trex-stopped" ]; do
    true
done
rm /tmp/trex-stopped

# capture the output from trex
echo -e "\nOutput from trex:\n"
tmux capture-pane -S - -E - -p -t trex

echo -e "###########################################\n"

# kill the sleep that is keeping tmux running
pkill -f sleep
