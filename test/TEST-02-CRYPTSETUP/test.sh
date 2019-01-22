#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh
set -e
TEST_DESCRIPTION="cryptsetup systemd setup"
TEST_NO_NSPAWN=1

export TEST_BASE_DIR="/var/opt/systemd-tests/test/"
. $TEST_BASE_DIR/test-functions

test_run() {
    ret=1
    systemctl daemon-reload
    systemctl start testsuite.service || return 1
    systemctl status --full testsuite.service

    if run_nspawn; then
        check_result_nspawn || return 1
    else
        dwarn "can't run systemd-nspawn, skipping"
    fi
    [[ -f /failed ]] && cat /failed
    test -s /failed && ret=$(($ret+1))
    [[ -e /testok ]] && ret=0
    return $ret
}

test_setup() {
    sfdisk "/dev/vdb" <<EOF
,90M
,
EOF

    echo -n test >$TESTDIR/keyfile
    cryptsetup -q luksFormat /dev/vdb1 $TESTDIR/keyfile
    cryptsetup luksOpen /dev/vdb1 varcrypt <$TESTDIR/keyfile
    mkfs.ext3 -L var /dev/mapper/varcrypt
    sed -i '/ \/var /d' /etc/fstab

    (
        LOG_LEVEL=5
        eval $(udevadm info --export --query=env --name=/dev/mapper/varcrypt)
        eval $(udevadm info --export --query=env --name=/dev/vdb1)

        # setup the testsuite service
        cat >/etc/systemd/system/testsuite.service <<EOF
[Unit]
Description=Testsuite service
After=multi-user.target

[Service]
ExecStart=/bin/sh -x -c 'systemctl --state=failed --no-legend --no-pager > /failed ; echo OK > /testok'
Type=oneshot
EOF

        cat >/etc/crypttab <<EOF
$DM_NAME UUID=$ID_FS_UUID /etc/varkey
EOF
        echo -n test > /etc/varkey
        cat /etc/crypttab | ddebug

        cat >>/etc/fstab <<EOF
/dev/mapper/varcrypt    /var    ext3    defaults 0 1
EOF
    ) || return 1

    cryptsetup luksClose /dev/mapper/varcrypt
}

test_cleanup() {
    for service in testsuite.service; do
        rm /etc/systemd/system/$service
    done
    [[ -e /testok ]] && rm /testok
    [[ -e /failed ]] && rm /failed

    rm /etc/systemd/system/testsuite.service
    rm /etc/varkey
    rm /etc/crypttab
    sed -i '/varcrypt/d' /etc/fstab
    return 0
}

do_test "$@"
