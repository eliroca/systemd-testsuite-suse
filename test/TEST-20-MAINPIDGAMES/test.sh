#!/bin/bash
set -e
TEST_DESCRIPTION="test changing main PID"

export TEST_BASE_DIR=/var/opt/systemd-tests/test
. $TEST_BASE_DIR/test-functions

test_run() {
    ret=1
    systemctl daemon-reload
    systemctl start testsuite.service || return 1
    systemctl status --full testsuite.service
    if [ -z "$TEST_NO_NSPAWN" ]; then
        if run_nspawn; then
            check_result_nspawn || return 1
        else
            dwarn "can't run systemd-nspawn, skipping"
        fi
    fi
    test -s /failed && ret=$(($ret+1))
    [[ -e /testok ]] && ret=0
    return $ret
}

test_setup() {
    mkdir -p $TESTDIR/root
    initdir=$TESTDIR/root
    STRIP_BINARIES=no

    (
        LOG_LEVEL=5

        setup_basic_environment

        # setup the testsuite service
        cat >$initdir/etc/systemd/system/testsuite.service <<EOF
[Unit]
Description=Testsuite service

[Service]
ExecStart=/bin/bash -x /testsuite.sh
ExecStartPost=/bin/sh -x -c 'systemctl --state=failed --no-pager > /failed'
Type=oneshot
StandardOutput=kmsg
StandardError=kmsg
NotifyAccess=all
EOF
        cp testsuite.sh /

        for service in testsuite.service; do
            cp $initdir/etc/systemd/system/$service /etc/systemd/system/
        done

        setup_testsuite
    )
    setup_nspawn_root

    # mask some services that we do not want to run in these tests
    [[ -f /etc/systemd/system/systemd-hwdb-update.service ]] && ln -fs /dev/null /etc/systemd/system/systemd-hwdb-update.service
    [[ -f /etc/systemd/system/systemd-journal-catalog-update.service ]] && ln -fs /dev/null /etc/systemd/system/systemd-journal-catalog-update.service
    [[ -f /etc/systemd/system/systemd-networkd.service ]] && ln -fs /dev/null /etc/systemd/system/systemd-networkd.service
    [[ -f /etc/systemd/system/systemd-networkd.socket ]] && ln -fs /dev/null /etc/systemd/system/systemd-networkd.socket
    [[ -f /etc/systemd/system/systemd-resolved.service ]] && ln -fs /dev/null /etc/systemd/system/systemd-resolved.service
    [[ -f /etc/systemd/system/systemd-machined.service ]] && ln -fs /dev/null /etc/systemd/system/systemd-machined.service
}

test_cleanup() {
    for service in testsuite.service; do
         rm /etc/systemd/system/$service
    done
    [[ -e /testok ]] && rm /testok
    [[ -e /failed ]] && rm /failed
    rm /testsuite.sh
    return 0
}

do_test "$@"
