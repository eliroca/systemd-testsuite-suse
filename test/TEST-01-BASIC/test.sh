#!/bin/bash
set -e
TEST_DESCRIPTION="Basic systemd setup"
RUN_IN_UNPRIVILEGED_CONTAINER=${RUN_IN_UNPRIVILEGED_CONTAINER:-yes}

export TEST_BASE_DIR=/var/opt/systemd-tests/test
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
    test -s /failed && ret=$(($ret+1))
    [[ -e /testok ]] && ret=0
    return $ret
}

test_setup() {
    mkdir -p $TESTDIR/root
    initdir=$TESTDIR/root
    STRIP_BINARIES=no

    # Create what will eventually be our root filesystem onto an overlay
    (
        LOG_LEVEL=5

        setup_basic_environment

        # setup the testsuite service
        cat >$initdir/etc/systemd/system/testsuite.service <<EOF
[Unit]
Description=Testsuite service
After=multi-user.target

[Service]
ExecStart=/bin/sh -e -x -c 'systemctl --state=failed --no-pager > /failed ; systemctl daemon-reload ; echo SUSEtest OK > /testok'
Type=oneshot
EOF

        setup_testsuite
        cp $initdir/etc/systemd/system/testsuite.service /etc/systemd/system/testsuite.service
    )

    setup_nspawn_root
    rm -r $TESTDIR/root
}

test_cleanup() {
    for service in testsuite.service; do
        rm /etc/systemd/system/$service
    done
    [[ -e /testok ]] && rm /testok
    [[ -e /failed ]] && rm /failed
    return 0
}

do_test "$@"
