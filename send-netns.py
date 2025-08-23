#!/usr/bin/env python3
import os
import socket
import array
import sys


def send_netns(ns_name: str, action: str, socket_path="/var/run/netns-publisher.sock"):
    if action not in {"A", "D"}:
        raise ValueError(f"Invalid action: {action}")

    # Open your own network namespace FD
    ns_fd = os.open("/proc/self/ns/net", os.O_RDONLY)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path)

    # Send the FD via SCM_RIGHTS
    fds = array.array("i", [ns_fd])
    sock.sendmsg(
        [f"{action}\0{ns_name}".encode()],
        [(socket.SOL_SOCKET, socket.SCM_RIGHTS, fds.tobytes())],
    )

    sock.close()
    os.close(ns_fd)
    print(f"Sent netns '{ns_name}' to publisher")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <netns-name> <action>", file=sys.stderr)
        sys.exit(1)
    send_netns(sys.argv[1], sys.argv[2])
