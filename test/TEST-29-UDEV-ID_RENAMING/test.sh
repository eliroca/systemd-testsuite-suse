#!/bin/bash
set -e
TEST_DESCRIPTION="UDEV ID_RENAMING property"
TEST_NO_NSPAWN=1

export TEST_BASE_DIR=/var/opt/systemd-tests/test
. $TEST_BASE_DIR/test-functions
QEMU_TIMEOUT=300

test_setup() {
    initdir=$TESTDIR/root
    create_empty_image_rootdir

    (
        LOG_LEVEL=5
        eval $(udevadm info --export --query=env --name=${LOOPDEV}p2)

        setup_basic_environment
        mask_supporting_services

        # setup the testsuite service
        cat >$initdir/etc/systemd/system/testsuite.service <<EOF
[Unit]
Description=Testsuite service

[Service]
ExecStart=/bin/bash -x /testsuite.sh
Type=oneshot
EOF
        cp testsuite.sh /

        for service in testsuite.service; do
            cp $initdir/etc/systemd/system/$service /etc/systemd/system/
        done

        setup_testsuite
    )
}

test_run() {
    ret=1
    systemctl daemon-reload
    systemctl start testsuite.service || return 1
    ! systemctl -q is-failed testsuite.service
    test -s /failed && ret=$(($ret+1))
    [[ -e /testok ]] && ret=0
    return $ret
}

test_cleanup() {
    for service in testsuite.service; do
         rm /etc/systemd/system/$service
    done
    for file in $(ls /testok* /failed* 2>/dev/null); do
      rm $file
    done
    return 0
}

do_test "$@"
