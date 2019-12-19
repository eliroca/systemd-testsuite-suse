#!/bin/bash
set -e
TEST_DESCRIPTION="FailureAction= operation"

export TEST_BASE_DIR=/var/opt/systemd-tests/test
. $TEST_BASE_DIR/test-functions
QEMU_TIMEOUT=600

test_setup() {
    create_empty_image_rootdir

    (
        LOG_LEVEL=5
        eval $(udevadm info --export --query=env --name=${LOOPDEV}p2)

        setup_basic_environment

        # setup the testsuite service
        cat >$initdir/etc/systemd/system/testsuite.service <<EOF
[Unit]
Description=Testsuite service

[Service]
ExecStart=/bin/bash -x /testsuite.sh
ExecStopPost=/bin/sh -x -c 'systemctl --state=failed --no-pager > /failed'
Type=oneshot
EOF
        cp testsuite.sh $initdir/

        setup_testsuite
    )

    setup_nspawn_root

    mask_supporting_services_nspawn

}

do_test "$@"
