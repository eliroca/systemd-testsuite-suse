#!/bin/bash
set -e
TEST_DESCRIPTION="Ensure %j Wants directives work"
RUN_IN_UNPRIVILEGED_CONTAINER=yes

export TEST_BASE_DIR=/var/opt/systemd-tests/test
. $TEST_BASE_DIR/test-functions

test_run() {
    if [ -z "$TEST_NO_NSPAWN" ]; then
        if run_nspawn "nspawn-root"; then
            check_result_nspawn "nspawn-root" || return 1
        else
            dwarn "can't run systemd-nspawn, skipping"
        fi

        if [[ "$RUN_IN_UNPRIVILEGED_CONTAINER" = "yes" ]]; then
            if NSPAWN_ARGUMENTS="-U --private-network $NSPAWN_ARGUMENTS" run_nspawn "unprivileged-nspawn-root"; then
                check_result_nspawn "unprivileged-nspawn-root" || return 1
            else
                dwarn "can't run systemd-nspawn, skipping"
            fi
        fi
    fi
    ret=1
    systemctl daemon-reload
    systemctl start testsuite.service || return 1
    ! systemctl -q is-failed testsuite.service
    test -s /failed && ret=$(($ret+1))
    [[ -e /testok ]] && ret=0
    return $ret
}

test_setup() {
    initdir=$TESTDIR/root
    create_empty_image_rootdir

    # Create what will eventually be our root filesystem onto an overlay
    (
        LOG_LEVEL=5
        eval $(udevadm info --export --query=env --name=${LOOPDEV}p2)

        setup_basic_environment
        mask_supporting_services

        # Install nproc to determine # of CPUs for correct parallelization
        inst_binary nproc

        # Set up the services.
        cat >$initdir/etc/systemd/system/specifier-j-wants.service << EOF
[Unit]
Description=Wants with percent-j specifier
Wants=specifier-j-depends-%j.service
After=specifier-j-depends-%j.service

[Service]
Type=oneshot
ExecStart=test -f /tmp/test-specifier-j-%j
ExecStart=/bin/sh -c 'echo SUSE testOK > /testok'
EOF
        cat >$initdir/etc/systemd/system/specifier-j-depends-wants.service << EOF
[Unit]
Description=Dependent service for percent-j specifier

[Service]
Type=oneshot
ExecStart=touch /tmp/test-specifier-j-wants
EOF
        cat >$initdir/etc/systemd/system/testsuite.service << EOF
[Unit]
Description=Testsuite: Ensure %j Wants directives work
Wants=specifier-j-wants.service
After=specifier-j-wants.service

[Service]
Type=oneshot
ExecStart=/bin/true
EOF
        for service in testsuite.service specifier-j-wants.service specifier-j-depends-wants.service; do
            cp $initdir/etc/systemd/system/$service /etc/systemd/system/
        done

        setup_testsuite
    )

    setup_nspawn_root
}

test_cleanup() {
    for service in testsuite.service specifier-j-wants.service specifier-j-depends-wants.service; do
         rm /etc/systemd/system/$service
    done
    for file in $(ls /testok* /failed* 2>/dev/null); do
      rm $file
    done
    return 0
}

do_test "$@"
