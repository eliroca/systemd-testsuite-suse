#!/bin/bash
set -e
set -o pipefail

if journalctl -b -t systemd --grep '\.device: Changed plugged -> dead'; then
    exit 1
fi

echo SUSE testOK > /testok
exit 0
