#!/bin/bash
set -e
TEST_DESCRIPTION="systemd-nspawn smoke test"
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
        dracut_install busybox chmod rmdir unshare ip sysctl

	cp create-busybox-container /

        /create-busybox-container /nc-container
        initdir="/nc-container" dracut_install nc

        # setup the testsuite service
        cat >$initdir/etc/systemd/system/testsuite.service <<EOF
[Unit]
Description=Testsuite service

[Service]
ExecStart=$initdir/test-nspawn.sh
ExecStartPost=/bin/sh -x -c 'systemctl --state=failed --no-pager > /failed; echo OK > /testok'
Type=oneshot
StandardOutput=kmsg
StandardError=kmsg
EOF

        cat >$initdir/test-nspawn.sh <<'EOF'
#!/bin/bash
set -x
set -e
set -u
set -o pipefail

export SYSTEMD_LOG_LEVEL=debug

# check cgroup-v2
is_v2_supported=no
mkdir -p /tmp/cgroup2
if mount -t cgroup2 cgroup2 /tmp/cgroup2; then
    is_v2_supported=yes
    umount /tmp/cgroup2
fi
rmdir /tmp/cgroup2

# check cgroup namespaces
is_cgns_supported=no
if [[ -f /proc/1/ns/cgroup ]]; then
    is_cgns_supported=yes
fi

is_user_ns_supported=no
# On some systems (e.g. CentOS 7) the default limit for user namespaces
# is set to 0, which causes the following unshare syscall to fail, even
# with enabled user namespaces support. By setting this value explicitly
# we can ensure the user namespaces support to be detected correctly.
sysctl -w user.max_user_namespaces=10000
if unshare -U sh -c :; then
    is_user_ns_supported=yes
fi

function check_bind_tmp_path {
    # https://github.com/systemd/systemd/issues/4789
    local _root="/var/lib/machines/bind-tmp-path"
    /create-busybox-container "$_root"
    >/tmp/bind
    systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" --bind=/tmp/bind /bin/sh -c 'test -e /tmp/bind'
}

function check_norbind {
    # https://github.com/systemd/systemd/issues/13170
    local _root="/var/lib/machines/norbind-path"
    mkdir -p /tmp/binddir/subdir
    echo -n "outer" > /tmp/binddir/subdir/file
    mount -t tmpfs tmpfs /tmp/binddir/subdir
    echo -n "inner" > /tmp/binddir/subdir/file
    /create-busybox-container "$_root"
    systemd-nspawn --bind /lib64 --register=no -D "$_root" --bind /lib64 --bind /usr/lib64 --bind=/tmp/binddir:/mnt:norbind /bin/sh -c 'CONTENT=$(cat /mnt/subdir/file); if [[ $CONTENT != "outer" ]]; then echo "*** unexpected content: $CONTENT"; return 1; fi'
}

function check_notification_socket {
    # https://github.com/systemd/systemd/issues/4944
    local _cmd='echo a | $(busybox which nc) -U -u -w 1 /run/systemd/nspawn/notify'
    systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D /nc-container /bin/sh -x -c "$_cmd"
    systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D /nc-container -U /bin/sh -x -c "$_cmd"
}

function run {
    if [[ "$1" = "yes" && "$is_v2_supported" = "no" ]]; then
        printf "Unified cgroup hierarchy is not supported. Skipping.\n" >&2
        return 0
    fi
    if [[ "$2" = "yes" && "$is_cgns_supported" = "no" ]];  then
        printf "CGroup namespaces are not supported. Skipping.\n" >&2
        return 0
    fi

    local _root="/var/lib/machines/unified-$1-cgns-$2-api-vfs-writable-$3"
    /create-busybox-container "$_root"
    UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" -b
    UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" --private-network -b

    if UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" -U -b; then
       [[ "$is_user_ns_supported" = "yes" && "$3" = "network" ]] && return 1
    else
       [[ "$is_user_ns_supported" = "no" && "$3" = "network" ]] && return 1
    fi

    if UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" --private-network -U -b; then
       [[ "$is_user_ns_supported" = "yes" && "$3" = "yes" ]] && return 1
    else
       [[ "$is_user_ns_supported" = "no" && "$3" = "yes" ]] && return 1
    fi

    local _netns_opt="--network-namespace-path=/proc/self/ns/net"

    # --network-namespace-path and network-related options cannot be used together
    if UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" "$_netns_opt" --network-interface=lo -b; then
       return 1
    fi

    if UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" "$_netns_opt" --network-macvlan=lo -b; then
       return 1
    fi

    if UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" "$_netns_opt" --network-ipvlan=lo -b; then
       return 1
    fi

    if UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --register=no -D "$_root" "$_netns_opt" --network-veth -b; then
       return 1
    fi

    if UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" "$_netns_opt" --network-veth-extra=lo -b; then
       return 1
    fi

    if UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" "$_netns_opt" --network-bridge=lo -b; then
       return 1
    fi

    if UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" "$_netns_opt" --network-zone=zone -b; then
       return 1
    fi

    if UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" "$_netns_opt" --private-network -b; then
       return 1
    fi

    # test --network-namespace-path works with a network namespace created by "ip netns"
    ip netns add nspawn_test
    _netns_opt="--network-namespace-path=/run/netns/nspawn_test"
    UNIFIED_CGROUP_HIERARCHY="$1" SYSTEMD_NSPAWN_USE_CGNS="$2" SYSTEMD_NSPAWN_API_VFS_WRITABLE="$3" systemd-nspawn --bind /lib64 --bind /usr/lib64 --register=no -D "$_root" "$_netns_opt" /bin/ip a | grep -v -E '^1: lo.*UP'
    local r=$?
    ip netns del nspawn_test

    if [ $r -ne 0 ]; then
       return 1
    fi

    return 0
}

check_bind_tmp_path

check_norbind

check_notification_socket

for api_vfs_writable in yes no network; do
    run no no $api_vfs_writable
    run yes no $api_vfs_writable
    run no yes $api_vfs_writable
    run yes yes $api_vfs_writable
done

touch /testok
EOF

        chmod 0755 $initdir/test-nspawn.sh
        for service in testsuite.service; do
            cp $initdir/etc/systemd/system/$service /etc/systemd/system/
        done
        setup_testsuite
    )

    # mask some services that we do not want to run in these tests
    [[ -f /etc/systemd/system/systemd-hwdb-update.service ]] && ln -fs /dev/null /etc/systemd/system/systemd-hwdb-update.service
    [[ -f /etc/systemd/system/systemd-journal-catalog-update.service ]] && ln -fs /dev/null /etc/systemd/system/systemd-journal-catalog-update.service
    [[ -f /etc/systemd/system/systemd-networkd.service ]] && ln -fs /dev/null /etc/systemd/system/systemd-networkd.service
    [[ -f /etc/systemd/system/systemd-networkd.socket ]] && ln -fs /dev/null /etc/systemd/system/systemd-networkd.socket
    [[ -f /etc/systemd/system/systemd-resolved.service ]] && ln -fs /dev/null /etc/systemd/system/systemd-resolved.service
    [[ -f /etc/systemd/system/systemd-machined.service ]] && ln -fs /dev/null /etc/systemd/system/systemd-machined.service

}

test_cleanup() {
    for service in testsuite.service; do
         rm /etc/systemd/system/$service
    done
    rm /create-busybox-container
    rm -r /nc-container
    [[ -e /testok ]] && rm /testok
    [[ -e /failed ]] && rm /failed
    return 0

}

do_test "$@"
