#!/bin/bash

cd $(dirname "$0")
. ./common.sh

if [ $# -lt 2 ]; then
    echo "Usage: $0 fault_func target_host [params]"
    echo "fault_func list:"
    awk '
/^#faults/{infaults=1}
/^[a-zA-Z_]+\(\)[ ]*$/{
if (infaults==1)print $1
}
' ./common.sh |tr -d '()'
    exit 1
fi

$* 