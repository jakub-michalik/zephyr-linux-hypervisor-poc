#!/bin/bash
# ssh into Dom0 (QEMU forwards host port 2222 to guest port 22)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec ssh -q -i "$ROOT/images/poc_key" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=10 root@localhost "$@"
