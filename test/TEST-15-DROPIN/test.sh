#!/bin/bash
set -e
TEST_DESCRIPTION="Dropin tests"
TEST_NO_QEMU=1

. $TEST_BASE_DIR/test-functions

test_setup() {
    # create the basic filesystem layout
    setup_basic_environment

    # import the test scripts in the rootfs and plug them in systemd
    echo "testservice=$initdir/etc/systemd/system/testsuite.service"
    cp testsuite.service $initdir/etc/systemd/system/
    cp test-dropin.sh    $initdir/
    setup_testsuite

    # create dedicated rootfs for nspawn (located in $TESTDIR/nspawn-root)
    setup_nspawn_root
    mask_supporting_services_nspawn
}

do_test "$@"
