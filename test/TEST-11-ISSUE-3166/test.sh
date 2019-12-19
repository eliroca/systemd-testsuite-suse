#!/bin/bash
set -e
TEST_DESCRIPTION="https://github.com/systemd/systemd/issues/3166"
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

    # Create what will eventually be our root filesystem onto an overlay
    (
        LOG_LEVEL=5

        setup_basic_environment
        dracut_install false touch

        # setup the testsuite service
        cat >$initdir/etc/systemd/system/testsuite.service <<EOF
[Unit]
Description=Testsuite service

[Service]
ExecStart=$initdir/test-fail-on-restart.sh
ExecStartPost=/bin/sh -x -c 'systemctl status fail-on-restart.service > /failed; echo SUSEtest OK > /testok'
Type=oneshot
EOF

        cat >$initdir/etc/systemd/system/fail-on-restart.service <<EOF
[Unit]
Description=Fail on restart
StartLimitIntervalSec=1m
StartLimitBurst=3

[Service]
Type=simple
ExecStart=/bin/false
Restart=always
EOF


        cat >$initdir/test-fail-on-restart.sh <<'EOF'
#!/bin/bash -x

systemctl start fail-on-restart.service
active_state=$(systemctl show --property ActiveState fail-on-restart.service)
while [[ "$active_state" == "ActiveState=activating" || "$active_state" == "ActiveState=active" ]]; do
    sleep 1
    active_state=$(systemctl show --property ActiveState fail-on-restart.service)
done
systemctl is-failed fail-on-restart.service || exit 1
touch /testok
EOF

        chmod 0755 $initdir/test-fail-on-restart.sh
        setup_testsuite
    )


    # copy the units used by this test
    for service in testsuite.service fail-on-restart.service; do
        cp $initdir/etc/systemd/system/$service /etc/systemd/system/
    done

    mask_supporting_services
}

test_cleanup() {
    for service in testsuite.service fail-on-restart.service; do
         rm /etc/systemd/system/$service
    done
    [[ -e /testok ]] && rm /testok
    [[ -e /failed ]] && rm /failed
    return 0

}

do_test "$@"
