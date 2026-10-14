#!/usr/bin/env python3
"""A password-only SSH server for testing Shellpane's password logins (macOS sshd can only check real
account passwords). The SFTP subsystem is handed to OpenSSH's own /usr/libexec/sftp-server, so the
file protocol is the real one. Test use only: 127.0.0.1, one made-up user and password.

    python password_server.py PORT USER PASSWORD ROOT HOSTKEY
"""
import os
import socket
import subprocess
import sys
import threading

import paramiko

PORT, USER, PASSWORD, ROOT, HOSTKEY = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]


class Server(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        ok = username == USER and password == PASSWORD
        return paramiko.AUTH_SUCCESSFUL if ok else paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "password"

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_subsystem_request(self, channel, name):
        if name != "sftp":
            return False
        proc = subprocess.Popen(["/usr/libexec/sftp-server", "-d", ROOT], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

        def up():
            try:
                while True:
                    data = channel.recv(65536)
                    if not data:
                        break
                    proc.stdin.write(data)
                    proc.stdin.flush()
            finally:
                proc.stdin.close()

        def down():
            try:
                while True:
                    data = os.read(proc.stdout.fileno(), 65536)
                    if not data:
                        break
                    channel.sendall(data)
            finally:
                channel.close()

        threading.Thread(target=up, daemon=True).start()
        threading.Thread(target=down, daemon=True).start()
        return True


def handle(conn):
    t = paramiko.Transport(conn)
    t.add_server_key(paramiko.RSAKey(filename=HOSTKEY))
    t.start_server(server=Server())


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT))
    s.listen(8)
    print("ready", flush=True)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
