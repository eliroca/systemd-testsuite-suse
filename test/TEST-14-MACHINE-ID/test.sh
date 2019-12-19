#!/bin/bash
set -e
TEST_DESCRIPTION="/etc/machine-id testing"
TEST_NO_NSPAWN=1

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
        printf "556f48e837bc4424a710fa2e2c9d3e3c\ne3d\n" >$initdir/etc/machine-id
        dracut_install mount cmp

        # setup the testsuite service
        cat >$initdir/etc/systemd/system/testsuite.service <<EOF
[Unit]
Description=Testsuite service

[Service]
ExecStart=/bin/sh -e -x -c '$initdir/test-machine-id-setup.sh'
ExecStartPost=/bin/sh -x -c 'systemctl --state=failed --no-pager > /failed; echo SUSEtest OK > /testok'
Type=oneshot
EOF

cat >$initdir/test-machine-id-setup.sh <<'EOF'
#!/bin/bash

set -e
set -x

function setup_root {
    local _root="$1"
    mkdir -p "$_root"
    mount -t tmpfs tmpfs "$_root"
    mkdir -p "$_root/etc" "$_root/run"
}

function check {
    printf "Expected\n"
    cat "$1"
    printf "\nGot\n"
    cat "$2"
    cmp "$1" "$2"
}

r="$(pwd)/overwrite-broken-machine-id"
setup_root "$r"
systemd-machine-id-setup --print --root "$r"
echo abc >>"$r/etc/machine-id"
id=$(systemd-machine-id-setup --print --root "$r")
echo $id >expected
check expected "$r/etc/machine-id"

r="$(pwd)/transient-machine-id"
setup_root "$r"
systemd-machine-id-setup --print --root "$r"
echo abc >>"$r/etc/machine-id"
mount -o remount,ro "$r"
mount -t tmpfs tmpfs "$r/run"
transient_id=$(systemd-machine-id-setup --print --root "$r")
mount -o remount,rw "$r"
commited_id=$(systemd-machine-id-setup --print --commit --root "$r")
[[ "$transient_id" = "$commited_id" ]]
check "$r/etc/machine-id" "$r/run/machine-id"
EOF
chmod +x $initdir/test-machine-id-setup.sh

        for service in testsuite.service; do
            cp $initdir/etc/systemd/system/$service /etc/systemd/system/
        done

        setup_testsuite
    )
    mask_supporting_services
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
