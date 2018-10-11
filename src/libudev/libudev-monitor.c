/* SPDX-License-Identifier: LGPL-2.1+ */

#include <errno.h>
#include <linux/filter.h>
#include <linux/netlink.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "libudev.h"

#include "alloc-util.h"
#include "device-private.h"
#include "device-util.h"
#include "fd-util.h"
#include "fileio.h"
#include "format-util.h"
#include "hashmap.h"
#include "libudev-device-internal.h"
#include "libudev-private.h"
#include "missing.h"
#include "mount-util.h"
#include "set.h"
#include "socket-util.h"
#include "string-util.h"
#include "strv.h"

/**
 * SECTION:libudev-monitor
 * @short_description: device event source
 *
 * Connects to a device event source.
 */

/**
 * udev_monitor:
 *
 * Opaque object handling an event source.
 */
struct udev_monitor {
        struct udev *udev;
        unsigned n_ref;
        int sock;
        union sockaddr_union snl;
        union sockaddr_union snl_trusted_sender;
        union sockaddr_union snl_destination;
        socklen_t addrlen;
        Hashmap *subsystem_filter;
        Set *tag_filter;
        bool bound;
};

enum udev_monitor_netlink_group {
        UDEV_MONITOR_NONE,
        UDEV_MONITOR_KERNEL,
        UDEV_MONITOR_UDEV,
};

#define UDEV_MONITOR_MAGIC                0xfeedcafe
struct udev_monitor_netlink_header {
        /* "libudev" prefix to distinguish libudev and kernel messages */
        char prefix[8];
        /*
         * magic to protect against daemon <-> library message format mismatch
         * used in the kernel from socket filter rules; needs to be stored in network order
         */
        unsigned magic;
        /* total length of header structure known to the sender */
        unsigned header_size;
        /* properties string buffer */
        unsigned properties_off;
        unsigned properties_len;
        /*
         * hashes of primary device properties strings, to let libudev subscribers
         * use in-kernel socket filters; values need to be stored in network order
         */
        unsigned filter_subsystem_hash;
        unsigned filter_devtype_hash;
        unsigned filter_tag_bloom_hi;
        unsigned filter_tag_bloom_lo;
};

static int udev_monitor_set_nl_address(struct udev_monitor *udev_monitor) {
        union sockaddr_union snl;
        socklen_t addrlen;

        assert(udev_monitor);

        /* Get the address the kernel has assigned us.
         * It is usually, but not necessarily the pid. */
        addrlen = sizeof(struct sockaddr_nl);
        if (getsockname(udev_monitor->sock, &snl.sa, &addrlen) < 0)
                return -errno;

        udev_monitor->snl.nl.nl_pid = snl.nl.nl_pid;
        return 0;
}

struct udev_monitor *udev_monitor_new_from_netlink_fd(struct udev *udev, const char *name, int fd) {
        _cleanup_(udev_monitor_unrefp) struct udev_monitor *udev_monitor = NULL;
        _cleanup_close_ int sock = -1;
        unsigned group;
        int r;

        assert_return_errno(!name || STR_IN_SET(name, "udev", "kernel"), NULL, EINVAL);

        if (!name)
                group = UDEV_MONITOR_NONE;
        else if (streq(name, "udev")) {
                /*
                 * We do not support subscribing to uevents if no instance of
                 * udev is running. Uevents would otherwise broadcast the
                 * processing data of the host into containers, which is not
                 * desired.
                 *
                 * Containers will currently not get any udev uevents, until
                 * a supporting infrastructure is available.
                 *
                 * We do not set a netlink multicast group here, so the socket
                 * will not receive any messages.
                 */
                if (access("/run/udev/control", F_OK) < 0 && dev_is_devtmpfs() <= 0) {
                        log_debug("The udev service seems not to be active, disabling the monitor");
                        group = UDEV_MONITOR_NONE;
                } else
                        group = UDEV_MONITOR_UDEV;
        } else {
                assert(streq(name, "kernel"));
                group = UDEV_MONITOR_KERNEL;
        }

        if (fd < 0) {
                sock = socket(PF_NETLINK, SOCK_RAW|SOCK_CLOEXEC|SOCK_NONBLOCK, NETLINK_KOBJECT_UEVENT);
                if (sock < 0) {
                        log_debug_errno(errno, "Failed to create socket: %m");
                        return NULL;
                }
        }

        udev_monitor = new(struct udev_monitor, 1);
        if (!udev_monitor) {
                errno = ENOMEM;
                return NULL;
        }

        *udev_monitor = (struct udev_monitor) {
                .udev = udev,
                .n_ref = 1,
                .sock = fd >= 0 ? fd : TAKE_FD(sock),
                .bound = fd >= 0,
                .snl.nl.nl_family = AF_NETLINK,
                .snl.nl.nl_groups = group,

                /* default destination for sending */
                .snl_destination.nl.nl_family = AF_NETLINK,
                .snl_destination.nl.nl_groups = UDEV_MONITOR_UDEV,
        };

        if (fd >= 0) {
                r = udev_monitor_set_nl_address(udev_monitor);
                if (r < 0) {
                        log_debug_errno(r, "Failed to set netlink address: %m");
                        return NULL;
                }
        }

        return TAKE_PTR(udev_monitor);
}

/**
 * udev_monitor_new_from_netlink:
 * @udev: udev library context
 * @name: name of event source
 *
 * Create new udev monitor and connect to a specified event
 * source. Valid sources identifiers are "udev" and "kernel".
 *
 * Applications should usually not connect directly to the
 * "kernel" events, because the devices might not be useable
 * at that time, before udev has configured them, and created
 * device nodes. Accessing devices at the same time as udev,
 * might result in unpredictable behavior. The "udev" events
 * are sent out after udev has finished its event processing,
 * all rules have been processed, and needed device nodes are
 * created.
 *
 * The initial refcount is 1, and needs to be decremented to
 * release the resources of the udev monitor.
 *
 * Returns: a new udev monitor, or #NULL, in case of an error
 **/
_public_ struct udev_monitor *udev_monitor_new_from_netlink(struct udev *udev, const char *name) {
        return udev_monitor_new_from_netlink_fd(udev, name, -1);
}

static void bpf_stmt(struct sock_filter *ins, unsigned *i,
                     unsigned short code, unsigned data) {
        ins[(*i)++] = (struct sock_filter) {
                .code = code,
                .k = data,
        };
}

static void bpf_jmp(struct sock_filter *ins, unsigned *i,
                    unsigned short code, unsigned data,
                    unsigned short jt, unsigned short jf) {
        ins[(*i)++] = (struct sock_filter) {
                .code = code,
                .jt = jt,
                .jf = jf,
                .k = data,
        };
}

/**
 * udev_monitor_filter_update:
 * @udev_monitor: monitor
 *
 * Update the installed socket filter. This is only needed,
 * if the filter was removed or changed.
 *
 * Returns: 0 on success, otherwise a negative error value.
 */
_public_ int udev_monitor_filter_update(struct udev_monitor *udev_monitor) {
        struct sock_filter ins[512] = {};
        struct sock_fprog filter;
        const char *subsystem, *devtype, *tag;
        unsigned i = 0;
        Iterator it;

        assert_return(udev_monitor, -EINVAL);

        if (hashmap_isempty(udev_monitor->subsystem_filter) &&
            set_isempty(udev_monitor->tag_filter))
                return 0;

        /* load magic in A */
        bpf_stmt(ins, &i, BPF_LD|BPF_W|BPF_ABS, offsetof(struct udev_monitor_netlink_header, magic));
        /* jump if magic matches */
        bpf_jmp(ins, &i, BPF_JMP|BPF_JEQ|BPF_K, UDEV_MONITOR_MAGIC, 1, 0);
        /* wrong magic, pass packet */
        bpf_stmt(ins, &i, BPF_RET|BPF_K, 0xffffffff);

        if (!set_isempty(udev_monitor->tag_filter)) {
                int tag_matches = set_size(udev_monitor->tag_filter);

                /* add all tags matches */
                SET_FOREACH(tag, udev_monitor->tag_filter, it) {
                        uint64_t tag_bloom_bits = util_string_bloom64(tag);
                        uint32_t tag_bloom_hi = tag_bloom_bits >> 32;
                        uint32_t tag_bloom_lo = tag_bloom_bits & 0xffffffff;

                        /* load device bloom bits in A */
                        bpf_stmt(ins, &i, BPF_LD|BPF_W|BPF_ABS, offsetof(struct udev_monitor_netlink_header, filter_tag_bloom_hi));
                        /* clear bits (tag bits & bloom bits) */
                        bpf_stmt(ins, &i, BPF_ALU|BPF_AND|BPF_K, tag_bloom_hi);
                        /* jump to next tag if it does not match */
                        bpf_jmp(ins, &i, BPF_JMP|BPF_JEQ|BPF_K, tag_bloom_hi, 0, 3);

                        /* load device bloom bits in A */
                        bpf_stmt(ins, &i, BPF_LD|BPF_W|BPF_ABS, offsetof(struct udev_monitor_netlink_header, filter_tag_bloom_lo));
                        /* clear bits (tag bits & bloom bits) */
                        bpf_stmt(ins, &i, BPF_ALU|BPF_AND|BPF_K, tag_bloom_lo);
                        /* jump behind end of tag match block if tag matches */
                        tag_matches--;
                        bpf_jmp(ins, &i, BPF_JMP|BPF_JEQ|BPF_K, tag_bloom_lo, 1 + (tag_matches * 6), 0);
                }

                /* nothing matched, drop packet */
                bpf_stmt(ins, &i, BPF_RET|BPF_K, 0);
        }

        /* add all subsystem matches */
        if (!hashmap_isempty(udev_monitor->subsystem_filter)) {
                HASHMAP_FOREACH_KEY(devtype, subsystem, udev_monitor->subsystem_filter, it) {
                        uint32_t hash = util_string_hash32(subsystem);

                        /* load device subsystem value in A */
                        bpf_stmt(ins, &i, BPF_LD|BPF_W|BPF_ABS, offsetof(struct udev_monitor_netlink_header, filter_subsystem_hash));
                        if (!devtype) {
                                /* jump if subsystem does not match */
                                bpf_jmp(ins, &i, BPF_JMP|BPF_JEQ|BPF_K, hash, 0, 1);
                        } else {
                                hash = util_string_hash32(devtype);

                                /* jump if subsystem does not match */
                                bpf_jmp(ins, &i, BPF_JMP|BPF_JEQ|BPF_K, hash, 0, 3);
                                /* load device devtype value in A */
                                bpf_stmt(ins, &i, BPF_LD|BPF_W|BPF_ABS, offsetof(struct udev_monitor_netlink_header, filter_devtype_hash));
                                /* jump if value does not match */
                                bpf_jmp(ins, &i, BPF_JMP|BPF_JEQ|BPF_K, hash, 0, 1);
                        }

                        /* matched, pass packet */
                        bpf_stmt(ins, &i, BPF_RET|BPF_K, 0xffffffff);

                        if (i+1 >= ELEMENTSOF(ins))
                                return -E2BIG;
                }

                /* nothing matched, drop packet */
                bpf_stmt(ins, &i, BPF_RET|BPF_K, 0);
        }

        /* matched, pass packet */
        bpf_stmt(ins, &i, BPF_RET|BPF_K, 0xffffffff);

        /* install filter */
        filter = (struct sock_fprog) {
                .len = i,
                .filter = ins,
        };
        if (setsockopt(udev_monitor->sock, SOL_SOCKET, SO_ATTACH_FILTER, &filter, sizeof(filter)) < 0)
                return -errno;

        return 0;
}

int udev_monitor_allow_unicast_sender(struct udev_monitor *udev_monitor, struct udev_monitor *sender) {
        assert_return(udev_monitor, -EINVAL);
        assert_return(sender, -EINVAL);

        udev_monitor->snl_trusted_sender.nl.nl_pid = sender->snl.nl.nl_pid;
        return 0;
}

/**
 * udev_monitor_enable_receiving:
 * @udev_monitor: the monitor which should receive events
 *
 * Binds the @udev_monitor socket to the event source.
 *
 * Returns: 0 on success, otherwise a negative error value.
 */
_public_ int udev_monitor_enable_receiving(struct udev_monitor *udev_monitor) {
        const int on = 1;
        int r;

        assert_return(udev_monitor, -EINVAL);

        r = udev_monitor_filter_update(udev_monitor);
        if (r < 0)
                return log_debug_errno(r, "Failed to update filter: %m");

        if (!udev_monitor->bound) {
                if (bind(udev_monitor->sock, &udev_monitor->snl.sa, sizeof(struct sockaddr_nl)) < 0)
                        return log_debug_errno(errno, "Failed to bind udev monitor socket to event source: %m");

                udev_monitor->bound = true;
        }

        r = udev_monitor_set_nl_address(udev_monitor);
        if (r < 0)
                return log_debug_errno(r, "Failed to set address: %m");

        /* enable receiving of sender credentials */
        if (setsockopt(udev_monitor->sock, SOL_SOCKET, SO_PASSCRED, &on, sizeof(on)) < 0)
                return log_debug_errno(errno, "Failed to set socket option SO_PASSCRED: %m");

        return 0;
}

/**
 * udev_monitor_set_receive_buffer_size:
 * @udev_monitor: the monitor which should receive events
 * @size: the size in bytes
 *
 * Set the size of the kernel socket buffer. This call needs the
 * appropriate privileges to succeed.
 *
 * Returns: 0 on success, otherwise -1 on error.
 */
_public_ int udev_monitor_set_receive_buffer_size(struct udev_monitor *udev_monitor, int size) {
        assert_return(udev_monitor, -EINVAL);

        if (setsockopt(udev_monitor->sock, SOL_SOCKET, SO_RCVBUFFORCE, &size, sizeof(size)) < 0)
                return -errno;

        return 0;
}

int udev_monitor_disconnect(struct udev_monitor *udev_monitor) {
        assert(udev_monitor);

        udev_monitor->sock = safe_close(udev_monitor->sock);
        return 0;
}

static struct udev_monitor *udev_monitor_free(struct udev_monitor *udev_monitor) {
        assert(udev_monitor);

        udev_monitor_disconnect(udev_monitor);
        hashmap_free_free_free(udev_monitor->subsystem_filter);
        set_free_free(udev_monitor->tag_filter);
        return mfree(udev_monitor);
}

/**
 * udev_monitor_ref:
 * @udev_monitor: udev monitor
 *
 * Take a reference of a udev monitor.
 *
 * Returns: the passed udev monitor
 **/

/**
 * udev_monitor_unref:
 * @udev_monitor: udev monitor
 *
 * Drop a reference of a udev monitor. If the refcount reaches zero,
 * the bound socket will be closed, and the resources of the monitor
 * will be released.
 *
 * Returns: #NULL
 **/
DEFINE_PUBLIC_TRIVIAL_REF_UNREF_FUNC(struct udev_monitor, udev_monitor, udev_monitor_free);

/**
 * udev_monitor_get_udev:
 * @udev_monitor: udev monitor
 *
 * Retrieve the udev library context the monitor was created with.
 *
 * Returns: the udev library context
 **/
_public_ struct udev *udev_monitor_get_udev(struct udev_monitor *udev_monitor) {
        assert_return(udev_monitor, NULL);

        return udev_monitor->udev;
}

/**
 * udev_monitor_get_fd:
 * @udev_monitor: udev monitor
 *
 * Retrieve the socket file descriptor associated with the monitor.
 *
 * Returns: the socket file descriptor
 **/
_public_ int udev_monitor_get_fd(struct udev_monitor *udev_monitor) {
        assert_return(udev_monitor, -EINVAL);

        return udev_monitor->sock;
}

static int passes_filter(struct udev_monitor *udev_monitor, sd_device *device) {
        const char *tag, *subsystem, *devtype, *s, *d = NULL;
        Iterator i;
        int r;

        assert_return(udev_monitor, -EINVAL);
        assert_return(device, -EINVAL);

        if (hashmap_isempty(udev_monitor->subsystem_filter))
                goto tag;

        r = sd_device_get_subsystem(device, &s);
        if (r < 0)
                return r;

        r = sd_device_get_devtype(device, &d);
        if (r < 0 && r != -ENOENT)
                return r;

        HASHMAP_FOREACH_KEY(devtype, subsystem, udev_monitor->subsystem_filter, i) {
                if (!streq(s, subsystem))
                        continue;

                if (!devtype)
                        goto tag;

                if (!d)
                        continue;

                if (streq(d, devtype))
                        goto tag;
        }

        return 0;

tag:
        if (set_isempty(udev_monitor->tag_filter))
                return 1;

        SET_FOREACH(tag, udev_monitor->tag_filter, i)
                if (sd_device_has_tag(device, tag) > 0)
                        return 1;

        return 0;
}

static int udev_monitor_receive_device_one(struct udev_monitor *udev_monitor, sd_device **ret) {
        _cleanup_(sd_device_unrefp) sd_device *device = NULL;
        union {
                struct udev_monitor_netlink_header nlh;
                char raw[8192];
        } buf;
        struct iovec iov = {
                .iov_base = &buf,
                .iov_len = sizeof(buf)
        };
        char cred_msg[CMSG_SPACE(sizeof(struct ucred))];
        union sockaddr_union snl;
        struct msghdr smsg = {
                .msg_iov = &iov,
                .msg_iovlen = 1,
                .msg_control = cred_msg,
                .msg_controllen = sizeof(cred_msg),
                .msg_name = &snl,
                .msg_namelen = sizeof(snl),
        };
        struct cmsghdr *cmsg;
        struct ucred *cred;
        ssize_t buflen, bufpos;
        bool is_initialized = false;
        int r;

        assert(ret);

        buflen = recvmsg(udev_monitor->sock, &smsg, 0);
        if (buflen < 0) {
                if (errno != EINTR)
                        log_debug_errno(errno, "Failed to receive message: %m");
                return -errno;
        }

        if (buflen < 32 || (smsg.msg_flags & MSG_TRUNC))
                return log_debug_errno(EINVAL, "Invalid message length.");

        if (snl.nl.nl_groups == UDEV_MONITOR_NONE) {
                /* unicast message, check if we trust the sender */
                if (udev_monitor->snl_trusted_sender.nl.nl_pid == 0 ||
                    snl.nl.nl_pid != udev_monitor->snl_trusted_sender.nl.nl_pid)
                        return log_debug_errno(EAGAIN, "Unicast netlink message ignored.");

        } else if (snl.nl.nl_groups == UDEV_MONITOR_KERNEL) {
                if (snl.nl.nl_pid > 0)
                        return log_debug_errno(EAGAIN, "Multicast kernel netlink message from PID %"PRIu32" ignored.", snl.nl.nl_pid);
        }

        cmsg = CMSG_FIRSTHDR(&smsg);
        if (!cmsg || cmsg->cmsg_type != SCM_CREDENTIALS)
                return log_debug_errno(EAGAIN, "No sender credentials received, message ignored.");

        cred = (struct ucred*) CMSG_DATA(cmsg);
        if (cred->uid != 0)
                return log_debug_errno(EAGAIN, "Sender uid="UID_FMT", message ignored.", cred->uid);

        if (streq(buf.raw, "libudev")) {
                /* udev message needs proper version magic */
                if (buf.nlh.magic != htobe32(UDEV_MONITOR_MAGIC))
                        return log_debug_errno(EAGAIN, "Invalid message signature (%x != %x)",
                                               buf.nlh.magic, htobe32(UDEV_MONITOR_MAGIC));

                if (buf.nlh.properties_off+32 > (size_t) buflen)
                        return log_debug_errno(EAGAIN, "Invalid message length (%u > %zd)",
                                               buf.nlh.properties_off+32, buflen);

                bufpos = buf.nlh.properties_off;

                /* devices received from udev are always initialized */
                is_initialized = true;

        } else {
                /* kernel message with header */
                bufpos = strlen(buf.raw) + 1;
                if ((size_t) bufpos < sizeof("a@/d") || bufpos >= buflen)
                        return log_debug_errno(EAGAIN, "Invalid message length");

                /* check message header */
                if (!strstr(buf.raw, "@/"))
                        return log_debug_errno(EAGAIN, "Invalid message header");
        }

        r = device_new_from_nulstr(&device, (uint8_t*) &buf.raw[bufpos], buflen - bufpos);
        if (r < 0)
                return log_debug_errno(r, "Failed to create device: %m");

        if (is_initialized)
                device_set_is_initialized(device);

        /* skip device, if it does not pass the current filter */
        if (passes_filter(udev_monitor, device) <= 0)
                return 0;

        *ret = TAKE_PTR(device);
        return 1;
}

int udev_monitor_receive_sd_device(struct udev_monitor *udev_monitor, sd_device **ret) {
        struct pollfd pfd = {
                .fd = udev_monitor->sock,
                .events = POLLIN,
        };
        int r;

        assert(udev_monitor);
        assert(ret);

        for (;;) {
                /* r == 0 means a device is received but it does not pass the current filter. */
                r = udev_monitor_receive_device_one(udev_monitor, ret);
                if (r != 0)
                        return r;

                for (;;) {
                        /* wait next message */
                        r = poll(&pfd, 1, 0);
                        if (r < 0) {
                                if (IN_SET(errno, EINTR, EAGAIN))
                                        continue;

                                return -errno;
                        } else if (r == 0)
                                return -EAGAIN;

                        /* receive next message */
                        break;
                }
        }
}

/**
 * udev_monitor_receive_device:
 * @udev_monitor: udev monitor
 *
 * Receive data from the udev monitor socket, allocate a new udev
 * device, fill in the received data, and return the device.
 *
 * Only socket connections with uid=0 are accepted.
 *
 * The monitor socket is by default set to NONBLOCK. A variant of poll() on
 * the file descriptor returned by udev_monitor_get_fd() should to be used to
 * wake up when new devices arrive, or alternatively the file descriptor
 * switched into blocking mode.
 *
 * The initial refcount is 1, and needs to be decremented to
 * release the resources of the udev device.
 *
 * Returns: a new udev device, or #NULL, in case of an error
 **/
_public_ struct udev_device *udev_monitor_receive_device(struct udev_monitor *udev_monitor) {
        _cleanup_(sd_device_unrefp) sd_device *device = NULL;
        int r;

        assert_return(udev_monitor, NULL);

        r = udev_monitor_receive_sd_device(udev_monitor, &device);
        if (r < 0) {
                errno = -r;
                return NULL;
        }

        return udev_device_new(udev_monitor->udev, device);
}

static int udev_monitor_send_sd_device(
                struct udev_monitor *udev_monitor,
                struct udev_monitor *destination,
                sd_device *device) {

        struct udev_monitor_netlink_header nlh = {
                .prefix = "libudev",
                .magic = htobe32(UDEV_MONITOR_MAGIC),
                .header_size = sizeof nlh,
        };
        struct iovec iov[2] = {
                { .iov_base = &nlh, .iov_len = sizeof nlh },
        };
        struct msghdr smsg = {
                .msg_iov = iov,
                .msg_iovlen = 2,
        };
        uint64_t tag_bloom_bits;
        const char *buf, *val;
        ssize_t count;
        size_t blen;
        int r;

        assert(udev_monitor);
        assert(device);

        r = device_get_properties_nulstr(device, (const uint8_t **) &buf, &blen);
        if (r < 0)
                return log_debug_errno(r, "Failed to get device properties: %m");
        if (blen < 32) {
                log_debug("Device buffer is too small to contain a valid device");
                return -EINVAL;
        }

        /* fill in versioned header */
        r = sd_device_get_subsystem(device, &val);
        if (r < 0)
                return log_debug_errno(r, "Failed to get device subsystem: %m");
        nlh.filter_subsystem_hash = htobe32(util_string_hash32(val));

        if (sd_device_get_devtype(device, &val) >= 0 && val)
                nlh.filter_devtype_hash = htobe32(util_string_hash32(val));

        /* add tag bloom filter */
        tag_bloom_bits = 0;
        FOREACH_DEVICE_TAG(device, val)
                tag_bloom_bits |= util_string_bloom64(val);

        if (tag_bloom_bits > 0) {
                nlh.filter_tag_bloom_hi = htobe32(tag_bloom_bits >> 32);
                nlh.filter_tag_bloom_lo = htobe32(tag_bloom_bits & 0xffffffff);
        }

        /* add properties list */
        nlh.properties_off = iov[0].iov_len;
        nlh.properties_len = blen;
        iov[1] = (struct iovec) {
                .iov_base = (char*) buf,
                .iov_len = blen,
        };

        /*
         * Use custom address for target, or the default one.
         *
         * If we send to a multicast group, we will get
         * ECONNREFUSED, which is expected.
         */
        smsg.msg_name = destination ? &destination->snl : &udev_monitor->snl_destination;
        smsg.msg_namelen = sizeof(struct sockaddr_nl);
        count = sendmsg(udev_monitor->sock, &smsg, 0);
        if (count < 0) {
                if (!destination && errno == ECONNREFUSED) {
                        log_debug("Passed device to netlink monitor %p", udev_monitor);
                        return 0;
                } else
                        return log_debug_errno(errno, "Failed to send device to netlink monitor %p", udev_monitor);
        }

        log_debug("Passed %zi byte device to netlink monitor %p", count, udev_monitor);
        return count;
}

int udev_monitor_send_device(
                struct udev_monitor *udev_monitor,
                struct udev_monitor *destination,
                struct udev_device *udev_device) {
        assert(udev_device);

        return udev_monitor_send_sd_device(udev_monitor, destination, udev_device->device);
}

/**
 * udev_monitor_filter_add_match_subsystem_devtype:
 * @udev_monitor: the monitor
 * @subsystem: the subsystem value to match the incoming devices against
 * @devtype: the devtype value to match the incoming devices against
 *
 * This filter is efficiently executed inside the kernel, and libudev subscribers
 * will usually not be woken up for devices which do not match.
 *
 * The filter must be installed before the monitor is switched to listening mode.
 *
 * Returns: 0 on success, otherwise a negative error value.
 */
_public_ int udev_monitor_filter_add_match_subsystem_devtype(struct udev_monitor *udev_monitor, const char *subsystem, const char *devtype) {
        _cleanup_free_ char *s = NULL, *d = NULL;
        int r;

        assert_return(udev_monitor, -EINVAL);
        assert_return(subsystem, -EINVAL);

        s = strdup(subsystem);
        if (!s)
                return -ENOMEM;

        if (devtype) {
                d = strdup(devtype);
                if (!d)
                        return -ENOMEM;
        }

        r = hashmap_ensure_allocated(&udev_monitor->subsystem_filter, NULL);
        if (r < 0)
                return r;

        r = hashmap_put(udev_monitor->subsystem_filter, s, d);
        if (r < 0)
                return r;

        s = d = NULL;
        return 0;
}

/**
 * udev_monitor_filter_add_match_tag:
 * @udev_monitor: the monitor
 * @tag: the name of a tag
 *
 * This filter is efficiently executed inside the kernel, and libudev subscribers
 * will usually not be woken up for devices which do not match.
 *
 * The filter must be installed before the monitor is switched to listening mode.
 *
 * Returns: 0 on success, otherwise a negative error value.
 */
_public_ int udev_monitor_filter_add_match_tag(struct udev_monitor *udev_monitor, const char *tag) {
        _cleanup_free_ char *t = NULL;
        int r;

        assert_return(udev_monitor, -EINVAL);
        assert_return(tag, -EINVAL);

        t = strdup(tag);
        if (!t)
                return -ENOMEM;

        r = set_ensure_allocated(&udev_monitor->tag_filter, &string_hash_ops);
        if (r < 0)
                return r;

        r = set_put(udev_monitor->tag_filter, t);
        if (r == -EEXIST)
                return 0;
        if (r < 0)
                return r;

        TAKE_PTR(t);
        return 0;
}

/**
 * udev_monitor_filter_remove:
 * @udev_monitor: monitor
 *
 * Remove all filters from monitor.
 *
 * Returns: 0 on success, otherwise a negative error value.
 */
_public_ int udev_monitor_filter_remove(struct udev_monitor *udev_monitor) {
        static const struct sock_fprog filter = { 0, NULL };

        assert_return(udev_monitor, -EINVAL);

        udev_monitor->subsystem_filter = hashmap_free_free_free(udev_monitor->subsystem_filter);
        udev_monitor->tag_filter = set_free_free(udev_monitor->tag_filter);

        if (setsockopt(udev_monitor->sock, SOL_SOCKET, SO_ATTACH_FILTER, &filter, sizeof(filter)) < 0)
                return -errno;

        return 0;
}
