#!/bin/bash
set -e
TEST_DESCRIPTION="Resource limits-related tests"

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

    # Create what will eventually be our root filesystem onto an overlay
    (
        LOG_LEVEL=5

        setup_basic_environment

        #set test limit
        cat >$initdir/etc/systemd/system.conf <<EOF
[Manager]
DefaultLimitNOFILE=10000:16384
EOF

        # setup the testsuite service
        cat >$initdir/etc/systemd/system/testsuite.service <<EOF
[Unit]
Description=Testsuite service

[Service]
ExecStart=$TESTDIR/nspawn-root/test-rlimits.sh
ExecStart=/bin/sh -e -x -c 'systemctl --state=failed --no-pager > /failed ; systemctl daemon-reload ; echo SUSEtest OK > /testok'
Type=oneshot
EOF

        # copy the units used by this test
        cp $initdir/etc/systemd/system/testsuite.service /etc/systemd/system/testsuite.service
        mv /etc/systemd/system.conf /etc/systemd/system.conf.orig
        cp $initdir/etc/systemd/system.conf /etc/systemd/
        cp test-rlimits.sh $initdir/

        setup_testsuite
    ) || return 1

    setup_nspawn_root
    rm -r $TESTDIR/root

    mask_supporting_services
}

test_cleanup() {
    for service in testsuite.service; do
         rm /etc/systemd/system/$service
    done
    mv /etc/systemd/system.conf.orig /etc/systemd/system.conf
    [[ -e /testok ]] && rm /testok
    [[ -e /failed ]] && rm /failed
    return 0

}

do_test "$@"
