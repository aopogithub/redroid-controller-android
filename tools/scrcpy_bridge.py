#!/usr/bin/env python3
"""
Scrcpy TCP bridge for Flutter app.
Mode 1 (default): Creates adb reverse tunnel + forwards to Unix socket
Mode 2 (--tcp): Pure TCP bridge for device-side Flutter app

Usage:
  python3 scrcpy_bridge.py           # Unix socket mode (host Flutter)
  python3 scrcpy_bridge.py --tcp     # TCP mode (device Flutter via adb reverse)
"""
import socket
import struct
import os
import sys
import select
import subprocess
import random
import signal

TCP_PORT = int(os.environ.get('SCRCPY_TCP_PORT', '7300'))
DEVICE_TCP_PORT = int(os.environ.get('SCRCPY_DEVICE_PORT', '7400'))
SOCKET_PATH = '/tmp/scrcpy_video.sock'
ADB = os.environ.get('ADB', '/opt/android-sdk/platform-tools/adb')
DEVICE = os.environ.get('DEVICE', '192.168.101.188:5555')
TCP_MODE = '--tcp' in sys.argv

def cleanup(signum=None, frame=None):
    try: os.unlink(SOCKET_PATH)
    except: pass
    try: subprocess.run([ADB, '-s', DEVICE, 'reverse', '--remove-all'], capture_output=True)
    except: pass
    sys.exit(0)

signal.signal(signal.SIGINT, cleanup)
signal.signal(signal.SIGTERM, cleanup)

def main():
    # Generate tunnel ID (must fit in Java int32)
    tunnel_id = f'{random.randint(0, 0x7FFFFFFF):08x}'
    socket_name = f'scrcpy_{tunnel_id}'

    print(f'[bridge] Tunnel ID: {tunnel_id}', flush=True)
    print(f'[bridge] Socket name: {socket_name}', flush=True)

    # Set up adb reverse tunnel
    subprocess.run([ADB, '-s', DEVICE, 'reverse', '--remove-all'], capture_output=True)
    result = subprocess.run(
        [ADB, '-s', DEVICE, 'reverse', f'localabstract:{socket_name}', f'tcp:{TCP_PORT}'],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f'[bridge] Failed: {result.stderr}', flush=True)
        sys.exit(1)
    print(f'[bridge] Reverse: {socket_name} -> tcp:{TCP_PORT}', flush=True)

    # Also set up reverse for device Flutter app (TCP mode)
    if TCP_MODE:
        result2 = subprocess.run(
            [ADB, '-s', DEVICE, 'reverse', f'tcp:{DEVICE_TCP_PORT}', f'tcp:{TCP_PORT}'],
            capture_output=True, text=True
        )
        print(f'[bridge] Device TCP reverse: tcp:{DEVICE_TCP_PORT} -> tcp:{TCP_PORT}', flush=True)

    # Start TCP listener for scrcpy server
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', TCP_PORT))
    server.listen(1)
    print(f'[bridge] TCP listener on port {TCP_PORT}', flush=True)
    print(f'[bridge] Start server with: scid={tunnel_id}', flush=True)
    print(f'[bridge] Waiting for scrcpy server...', flush=True)

    conn, addr = server.accept()
    print(f'[bridge] Scrcpy server connected from {addr}', flush=True)

    # Read 72-byte header
    header = b''
    while len(header) < 72:
        data = conn.recv(72 - len(header))
        if not data:
            print('[bridge] Connection closed before header')
            cleanup()
            return
        header += data

    device_name = header[:64].split(b'\x00')[0].decode('ascii', errors='replace')
    width = struct.unpack('>I', header[68:72])[0]
    print(f'[bridge] Device: {device_name}, Width: {width}', flush=True)

    if TCP_MODE:
        # TCP mode: Forward everything to a second TCP port for device Flutter
        device_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        device_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        device_server.bind(('0.0.0.0', DEVICE_TCP_PORT))
        device_server.listen(1)
        print(f'[bridge] Device TCP listener on port {DEVICE_TCP_PORT}', flush=True)
        print(f'[bridge] Waiting for Flutter app on device...', flush=True)

        device_conn, _ = device_server.accept()
        print('[bridge] Flutter app connected!', flush=True)

        # Forward header
        device_conn.sendall(header)

        # Bidirectional forwarding
        maxfd = max(conn.fileno(), device_conn.fileno()) + 1
        while True:
            rlist, _, _ = select.select([conn, device_conn], [], [], 10)
            if not rlist: break
            for s in rlist:
                data = s.recv(65536)
                if not data:
                    print('[bridge] Disconnected')
                    cleanup()
                    return
                target = device_conn if s == conn else conn
                target.sendall(data)
    else:
        # Unix socket mode: Forward to Unix socket for host Flutter
        try: os.unlink(SOCKET_PATH)
        except: pass

        video_server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        video_server.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o777)
        video_server.listen(1)
        print(f'[bridge] Unix socket: {SOCKET_PATH}', flush=True)
        print(f'[bridge] Waiting for Flutter app...', flush=True)

        with open('/tmp/scrcpy_ready', 'w') as f:
            f.write(f'{device_name} {socket_name} {TCP_PORT}')

        video_conn, _ = video_server.accept()
        print('[bridge] Flutter app connected!', flush=True)

        video_conn.sendall(header)

        maxfd = max(conn.fileno(), video_conn.fileno()) + 1
        while True:
            rlist, _, _ = select.select([conn, video_conn], [], [], 10)
            if not rlist: break
            for s in rlist:
                data = s.recv(65536)
                if not data:
                    print('[bridge] Disconnected')
                    cleanup()
                    return
                target = video_conn if s == conn else conn
                target.sendall(data)

    cleanup()

if __name__ == '__main__':
    main()
