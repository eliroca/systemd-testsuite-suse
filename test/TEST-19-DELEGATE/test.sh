#!/bin/bash
set -e
TEST_DESCRIPTION="test cgroup delegation in the unified hierarchy"
TEST_NO_NSPAWN=1

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
ExecStart=/bin/bash -x /testsuite.sh &>/testscript.out
ExecStartPost=/bin/sh -x -c 'systemctl --state=failed --no-pager > /failed'
Type=oneshot
StandardOutput=kmsg
StandardError=kmsg
EOF
        cp testsuite.sh /

        for service in testsuite.service; do
            cp $initdir/etc/systemd/system/$service /etc/systemd/system/
        done

        setup_testsuite
    )

   sed -i '/^[ !·······]*GRUB_CMDLINE_LINUX_DEFAULT.*/s/"$/ systemd.unified_cgroup_hierarchy=yes"/' /etc/default/grub
   grub2-mkconfig -o /boot/grub2/grub.cfg || return 1

   mask_supporting_services

}

test_cleanup() {
    for service in testsuite.service; do
         rm /etc/systemd/system/$service
    done
    [[ -e /testok ]] && rm /testok
    [[ -e /failed ]] && rm /failed
    [[ -e /testscript.out ]] && rm /testscript.out
    rm /testsuite.sh
    sed -i '/^[ !·······]*GRUB_CMDLINE_LINUX_DEFAULT.*/s/ systemd.unified_cgroup_hierarchy=yes//' /etc/default/grub
    grub2-mkconfig -o /boot/grub2/grub.cfg
    return 0
}

do_test "$@"
