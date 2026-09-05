#!/usr/bin/env bash
# Push a chunk build from mbp straight to the QA VM (mbp -> VM over NetBird),
# and optionally seed the base fixture. The Linux host only orchestrates.
#   Scripts/deploy-vm.sh <chunk> [fixture]
set -euo pipefail
CHUNK="${1:?chunk}"
VM="lume@mailternal-macos-vm.vpn.kayg.org"
ROOT="/Users/agents/mailternal-build/$CHUNK"
SRC="$ROOT/App/build/Build/Products/Debug/Mailternal.app"
ssh agents@mbp "test -d '$SRC' || { echo 'no built app at $SRC'; exit 1; }
  ssh -o StrictHostKeyChecking=no $VM 'mkdir -p ~/mailternal ~/mailternal-qa-base'
  rsync -a --delete '$SRC' $VM:~/mailternal/ && echo 'app -> vm'
  rsync -a '$ROOT/Scripts/vm-qa.sh' $VM:~/vm-qa.sh &&
    ssh $VM 'chmod +x ~/vm-qa.sh' && echo 'vm-qa.sh -> vm'
  rsync -a '$ROOT/Scripts/qa/tab-switch-latency-vm.sh' $VM:~/tab-switch-latency-vm.sh &&
    ssh $VM 'chmod +x ~/tab-switch-latency-vm.sh' && echo 'tab-switch-latency-vm.sh -> vm'
  if [ '${2:-}' = fixture ]; then
    rsync -a ~/mailternal-qa-ReaderIslands/ $VM:~/mailternal-qa-base/ && echo 'fixture -> vm'
  fi"
