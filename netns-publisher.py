#!/usr/bin/env python3
import os
import socket
import array
import sys
import ctypes
import ctypes.util
import shutil

# Lookup libc
libc_path = ctypes.util.find_library("c")
libc = ctypes.CDLL(libc_path, use_errno=True)

# Mount flags
MS_BIND = 0x1000

SOCKET_FD = 0  # systemd socket activation
NETNS_DIR = "/var/run/netns"


def sanitize_name(name: str) -> str:
    """Prevent path traversal."""
    if "/" in name or ".." in name:
        raise ValueError(f"Invalid netns name: {name}")
    return name


def mount_ns_fd(ns_fd: int, ns_name: str):
    target_path = os.path.join(NETNS_DIR, ns_name)
    # os.makedirs(target_path, exist_ok=True)
    if not os.path.exists(target_path):
        open(target_path, "a").close()

    source_path = f"/proc/self/fd/{ns_fd}".encode()
    target_path_bytes = target_path.encode()

    ret = libc.mount(source_path, target_path_bytes, None, MS_BIND, None)
    if ret != 0:
        e = ctypes.get_errno()
        raise OSError(e, f"mount failed: {os.strerror(e)}")
    print(f"Bound netns FD {ns_fd} -> {target_path}")


def unmount_ns(ns_name: str):
    target_path = os.path.join(NETNS_DIR, ns_name)
    if not os.path.exists(target_path):
        return
    ret = libc.umount(target_path.encode())
    if ret != 0:
        e = ctypes.get_errno()
        raise OSError(e, f"mount failed: {os.strerror(e)}")
    os.unlink(target_path)
    if os.path.exists(f"/etc/netns/{ns_name}"):
        shutil.rmtree(f"/etc/netns/{ns_name}")
    print(f"Unbound netns {target_path}")


def handle_connection(conn):
    fds = array.array("i")  # for SCM_RIGHTS
    msg, ancdata, *_ = conn.recvmsg(1024, socket.CMSG_LEN(4))
    raw_action, raw_name = msg.split(b"\0", 1)
    action = raw_action.decode().strip()
    if action not in {"A", "D"}:
        raise ValueError(f"Invalid action {action}")
    ns_name = sanitize_name(raw_name.decode().strip())
    if not ns_name:
        raise ValueError(f"Invalid name {ns_name}")

    if action == "A":
        for cmsg_level, cmsg_type, cmsg_data in ancdata:
            if cmsg_level == socket.SOL_SOCKET and cmsg_type == socket.SCM_RIGHTS:
                fds.frombytes(cmsg_data[:4])

        if not fds:
            print("No FD received!", file=sys.stderr)
            conn.close()
            return

        mount_ns_fd(fds[0], ns_name)
        os.close(fds[0])
    else:
        unmount_ns(ns_name)

    conn.close()


def main():
    sock = socket.socket(fileno=SOCKET_FD)
    # sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    # sock.bind("/var/run/netns-publisher.sock")
    sock.listen(1)
    print("Netns publisher ready")
    try:
        while True:
            conn, _ = sock.accept()
            try:
                handle_connection(conn)
            except Exception as e:
                print(f"Error handling connection: {e}", file=sys.stderr)
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()
        if os.path.exists("/var/run/netns-publisher.sock"):
            os.unlink("/var/run/netns-publisher.sock")


if __name__ == "__main__":
    main()
