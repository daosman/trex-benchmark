#!/bin/bash

pkt_sizes=(64 128 256 512 1024 1280 1512)
pkt_drop_rate='0.01'
pkt_tx_duration='20'

profile="stl/bench.py"

prefix="4-cores"

trex_dir="/opt/trex"

trex_server="trex.benchmark.svc.cluster.local"

cd ${trex_dir}
for size in "${pkt_sizes[@]}"
do

  test_name="${prefix}-${size}-bytes"
  ndr_cmd="./ndr --stl -v \
        --server ${trex_server} \
        --bi-dir \
        --port 0 1 \
        --pdr ${pkt_drop_rate} \
        --first_run_duration_time ${pkt_tx_duration} \
        --iter-time ${pkt_tx_duration} \
        --output ndr-${test_name}.json \
        --title ndr-${size}-bytes \
        --profile $profile  \
        --prof-tun size=${size}"
  ndr_cmd=$(echo "${ndr_cmd}" | sed -e "s/\s\+/ /g")
  echo $ndr_cmd
  eval $ndr_cmd
done

jq -c --slurp 'flatten' ndr-*.json > ndr-all.json
