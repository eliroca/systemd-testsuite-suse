#!/bin/bash
set -e
TEST_DESCRIPTION="https://github.com/systemd/systemd/issues/2691"
TEST_NO_NSPAWN=1

export TEST_BASE_DIR=/var/opt/systemd-tests/test
. $TEST_BASE_DIR/test-functions

test_run() {
    ret=1
    grep 'code=dumped, signal=SEGV' /testsuitestatus && echo SUSEtest OK > /testok || rm /testok
    systemctl --state=failed --no-pager > /failed
    [[ -e /testok ]] && ret=0 || ret=$(($ret+1))
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
        cat >$initdir/etc/systemd/system/testsuite.service <<'EOF'
[Unit]
Description=Testsuite service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo SUSEtest-firststage OK >/testok'
RemainAfterExit=yes
ExecStop=/bin/sh -c 'kill -SEGV $$$$'
TimeoutStopSec=270s
EOF
        cat >$initdir/etc/systemd/system/end.service <<'EOF'
[Unit]
Description=Record status after stopping the test
DefaultDependencies=no
After=shutdown.target
Before=umount.target

[Service]
Type=oneshot
ExecStart=/bin/sh -x -c 'systemctl status testsuite.service > /testsuitestatus'
TimeoutStartSec=5m
EOF
    )


    # copy the units used by this test
    cp $initdir/etc/systemd/system/testsuite.service /etc/systemd/system/testsuite.service
    cp $initdir/etc/systemd/system/end.service /etc/systemd/system/end.service

    [[ -d  /etc/systemd/system/reboot.target.wants ]] || mkdir /etc/systemd/system/reboot.target.wants
    ln -s /etc/systemd/system/end.service /etc/systemd/system/reboot.target.wants/end.service

    systemctl daemon-reload
    systemctl start testsuite.service || return 1

cat > /usr/lib/systemd/system-shutdown/debug.sh  <<'EOF'
#!/bin/sh
mount -o remount,rw /
dmesg > /shutdown-log.txt
mount -o remount,ro /
EOF
   chmod ugo+x /usr/lib/systemd/system-shutdown/debug.sh

   systemctl log-level debug
   systemctl log-target kmsg

   mask_supporting_services
}

test_cleanup() {
    for service in end.service testsuite.service; do
         rm -f /etc/systemd/system/$service
    done

    rm -f /usr/lib/systemd/system-shutdown/debug.sh
    rm -rf /etc/systemd/system/reboot.target.wants

    rm /usr/lib/systemd/system-shutdown/debug.sh
    rm /shutdown.log

    [[ -e /testok ]] && rm /testok
    [[ -e /failed ]] && rm /failed
    [[ -e /testesuitestatus ]] && rm /testsuitestatus
    return 0

}

do_test "$@"
