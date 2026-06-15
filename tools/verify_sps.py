#!/usr/bin/env python3
"""Verify SPS resolution parsing from Redroid H.264 stream."""
import socket, struct, sys, os, random

def send_adb_msg(sock, cmd, arg0, arg1, payload=b''):
    """Send ADB protocol message."""
    length = len(payload)
    # CRC32
    crc = 0xFFFFFFFF
    for b in payload:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0xEDB88320 if crc & 1 else 0)
    checksum = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF
    magic = (cmd ^ 0xFFFFFFFF) & 0xFFFFFFFF
    header = struct.pack('<6I', cmd, arg0, arg1, length, checksum, magic)
    sock.sendall(header + payload)

def recv_adb_msg(sock):
    """Receive ADB protocol message. Returns (cmd, arg0, arg1, payload)."""
    header = b''
    while len(header) < 24:
        chunk = sock.recv(24 - len(header))
        if not chunk:
            raise ConnectionError('Socket closed')
        header += chunk
    cmd, arg0, arg1, length, checksum, magic = struct.unpack('<6I', header)
    payload = b''
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            raise ConnectionError('Socket closed')
        payload += chunk
    return cmd, arg0, arg1, payload

# ADB command constants
CNXN = 0x4e584e43
OPEN = 0x4e45504f
OKAY = 0x59414b4f
WRTE = 0x45545257
CLSE = 0x45534c43

def adb_connect(host, port):
    """Connect to ADB daemon, return socket."""
    sock = socket.create_connection((host, port), timeout=10)
    send_adb_msg(sock, CNXN, 0x01000001, 4096, b'host::features=shell_v2,cmd\x00')
    cmd, *_ = recv_adb_msg(sock)
    if cmd != CNXN:
        raise Exception(f'CNXN failed: 0x{cmd:08x}')
    return sock

def adb_shell(sock, command, local_id=1):
    """Execute shell command via ADB. Returns output string."""
    send_adb_msg(sock, OPEN, local_id, 0, f'shell:{command}\0'.encode())
    cmd, arg0, arg1, payload = recv_adb_msg(sock)
    if cmd != OKAY:
        raise Exception(f'OPEN failed: 0x{cmd:08x}')
    
    output = b''
    remote_id = arg0
    while True:
        cmd, arg0, arg1, payload = recv_adb_msg(sock)
        if cmd == WRTE:
            output += payload
            send_adb_msg(sock, OKAY, local_id, arg0)
        elif cmd == CLSE:
            break
    return output.decode('utf-8', errors='replace').strip()

def adb_open_abstract(sock, socket_name, local_id=2):
    """Open connection to abstract socket. Returns (remote_id, reader)."""
    send_adb_msg(sock, OPEN, local_id, 0, f'localabstract:{socket_name}\0'.encode())
    cmd, arg0, arg1, payload = recv_adb_msg(sock)
    if cmd != OKAY:
        raise Exception(f'OPEN failed: 0x{cmd:08x} (expected OKAY)')
    return arg0  # remote_id

def read_exact(sock_reader, n):
    """Read exactly n bytes from buffered reader."""
    while len(sock_reader['buf']) < n:
        cmd, arg0, arg1, payload = recv_adb_msg(sock_reader['sock'])
        if cmd == WRTE:
            sock_reader['buf'] += payload
            send_adb_msg(sock_reader['sock'], OKAY, sock_reader['local_id'], arg0)
        elif cmd == CLSE:
            raise ConnectionError('Stream closed')
    result = sock_reader['buf'][:n]
    sock_reader['buf'] = sock_reader['buf'][n:]
    return result

def find_nal_units(data):
    """Find NAL units in H.264 bitstream. Yields (nal_type, nal_data)."""
    i = 0
    while i < len(data) - 3:
        # Find start code
        start_code_len = 0
        if data[i] == 0 and data[i+1] == 0:
            if i + 3 < len(data) and data[i+2] == 0 and data[i+3] == 1:
                start_code_len = 4
            elif data[i+2] == 1:
                start_code_len = 3
        if start_code_len == 0:
            i += 1
            continue

        nal_start = i + start_code_len
        if nal_start >= len(data):
            break
        nal_type = data[nal_start] & 0x1F

        # Find next start code
        j = nal_start + 1
        while j < len(data) - 3:
            if data[j] == 0 and data[j+1] == 0:
                if (j + 3 < len(data) and data[j+2] == 0 and data[j+3] == 1) or data[j+2] == 1:
                    break
            j += 1
        if j >= len(data) - 3:
            j = len(data)

        nal_data = data[nal_start:j]
        yield nal_type, nal_data
        i = j

class BitReader:
    """Bit-level reader for Exp-Golomb decoding."""
    def __init__(self, data, offset=0):
        self.data = data
        self.pos = offset * 8

    def read_bit(self):
        if self.pos >= len(self.data) * 8:
            return 0
        byte_idx = self.pos // 8
        bit_idx = self.pos % 8
        self.pos += 1
        return (self.data[byte_idx] >> (7 - bit_idx)) & 1

    def read_ue(self):
        """Read unsigned Exp-Golomb coded value."""
        zeros = 0
        while self.read_bit() == 0 and zeros < 32:
            zeros += 1
        # The terminating 1-bit was consumed by the loop.
        # Read 'zeros' info bits, then combine: value = (1 << zeros) + info - 1
        info = 0
        for _ in range(zeros):
            info = (info << 1) | self.read_bit()
        return ((1 << zeros) - 1) + info

    def read_se(self):
        """Read signed Exp-Golomb coded value."""
        val = self.read_ue()
        if val % 2 == 0:
            return -(val // 2)
        return (val + 1) // 2

def parse_sps(sps_data):
    """Parse SPS NAL unit and return (width, height) or None."""
    try:
        # Determine offset: start code (3/4 bytes) + NAL type byte (1 byte)
        # NAL data from find_nal_units starts at NAL header (no start code)
        i = 0
        if len(sps_data) > 4 and sps_data[0:4] == b'\x00\x00\x00\x01':
            i = 5  # 4-byte start code + NAL type
        elif len(sps_data) > 3 and sps_data[0:3] == b'\x00\x00\x01':
            i = 4  # 3-byte start code + NAL type
        else:
            i = 1  # no start code, just skip NAL type byte
        if i >= len(sps_data):
            return None

        br = BitReader(sps_data, i)

        profile_idc = br.read_ue()  # profile_idc (as ue for simplicity, but actually fixed 8 bits)

        # Re-read properly: profile_idc is 8 bits, not ue
        br = BitReader(sps_data, i)
        profile_idc_val = 0
        for bit_i in range(8):
            profile_idc_val = (profile_idc_val << 1) | br.read_bit()

        # constraint_set flags (6 bits) + reserved (2 bits)
        constraint_flags = 0
        for bit_i in range(8):
            constraint_flags = (constraint_flags << 1) | br.read_bit()

        # level_idc (8 bits)
        level_idc = 0
        for bit_i in range(8):
            level_idc = (level_idc << 1) | br.read_bit()

        br.read_ue()  # seq_parameter_set_id

        # High profile extras
        if profile_idc_val in (100, 110, 122, 244, 44, 83, 86, 118, 128):
            chroma_format_idc = br.read_ue()
            if chroma_format_idc == 3:
                br.read_bit()  # separate_colour_plane_flag
            br.read_ue()  # bit_depth_luma_minus8
            br.read_ue()  # bit_depth_chroma_minus8
            br.read_bit()  # qpprime_y_zero_transform_bypass_flag
            seq_scaling_matrix_present = br.read_bit()
            if seq_scaling_matrix_present:
                cnt = 8 if chroma_format_idc != 3 else 12
                for j in range(cnt):
                    if br.read_bit():  # seq_scaling_list_present
                        size = 16 if j < 6 else 64
                        last_scale = 8
                        next_scale = 8
                        for k in range(size):
                            if next_scale != 0:
                                delta = br.read_ue()
                                next_scale = (last_scale + delta + 256) % 256
                            last_scale = next_scale if next_scale != 0 else last_scale

        br.read_ue()  # log2_max_frame_num_minus4
        pic_order_cnt_type = br.read_ue()
        if pic_order_cnt_type == 0:
            br.read_ue()  # log2_max_pic_order_cnt_lsb_minus4
        elif pic_order_cnt_type == 1:
            br.read_bit()  # delta_pic_order_always_zero_flag
            br.read_ue()  # offset_for_non_ref_pic
            br.read_ue()  # offset_for_top_to_bottom_field
            num_ref_frames = br.read_ue()
            for _ in range(num_ref_frames):
                br.read_ue()

        br.read_ue()  # max_num_ref_frames
        br.read_bit()  # gaps_in_frame_num_value_allowed_flag

        pic_width_in_mbs = br.read_ue() + 1
        pic_height_in_map_units = br.read_ue() + 1
        frame_mbs_only = br.read_bit()

        width = pic_width_in_mbs * 16
        height = pic_height_in_map_units * (16 if frame_mbs_only else 32)

        # Skip frame_mbs_only_flag, direct_8x8_inference_flag, frame_cropping_flag
        if not frame_mbs_only:
            br.read_bit()  # mb_adaptive_frame_field_flag
        br.read_bit()  # direct_8x8_inference_flag
        frame_cropping_flag = br.read_bit()
        if frame_cropping_flag:
            crop_left = br.read_ue()
            crop_right = br.read_ue()
            crop_top = br.read_ue()
            crop_bottom = br.read_ue()
            # Adjust for cropping (YUV 4:2:0)
            width -= (crop_left + crop_right) * 2
            height -= (crop_top + crop_bottom) * 2

        return width, height
    except Exception as e:
        print(f'  SPS parse error: {e}')
        return None

def main():
    host = sys.argv[1] if len(sys.argv) > 1 else '192.168.101.188'
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5555
    socket_name = 'scrcpy'

    print(f'=== SPS Resolution Test ===')
    print(f'Target: {host}:{port}')
    print()

    # Step 1: Connect to ADB
    print('① ADB 连接...')
    sock = adb_connect(host, port)
    print('  ✓ ADB 已连接')

    # Step 2: Query wm size
    print('② 查询 wm size...')
    wm_output = adb_shell(sock, 'wm size', local_id=1)
    print(f'  → {wm_output}')

    import re
    match = re.search(r'Physical size:\s*(\d+)x(\d+)', wm_output)
    if match:
        wm_w, wm_h = int(match.group(1)), int(match.group(2))
        print(f'  → wm size: {wm_w}x{wm_h}')
    else:
        wm_w, wm_h = 720, 1280
        print(f'  → wm size 解析失败，使用默认 {wm_w}x{wm_h}')

    # Step 3: Kill old scrcpy server
    print('③ 清理旧 scrcpy...')
    try:
        kill_sock = adb_connect(host, port)
        adb_shell(kill_sock, 'pkill -9 -f scrcpy 2>/dev/null', local_id=1)
        kill_sock.close()
    except:
        pass
    import time; time.sleep(0.5)

    # Step 4: Push scrcpy server
    print('④ 检查 scrcpy-server.jar...')
    check_sock = adb_connect(host, port)
    ls_output = adb_shell(check_sock, 'ls -la /data/local/tmp/scrcpy-server.jar 2>/dev/null', local_id=1)
    check_sock.close()
    jar_path = '/usr/share/scrcpy/scrcpy-server'
    if 'scrcpy-server.jar' not in ls_output:
        print(f'  → 推送 jar...')
        os.system(f'adb -s {host}:{port} push {jar_path} /data/local/tmp/scrcpy-server.jar')
    else:
        print(f'  → jar 已存在')

    # Step 5: Start scrcpy server via ADB shell
    print('⑤ 启动 scrcpy server...')
    scid = -1  # Use default socket name like Dart code does
    print(f'  → scid={scid} (default socket)')
    
    server_sock = adb_connect(host, port)
    server_cmd = (
        f'CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / '
        f'com.genymobile.scrcpy.Server 3.3.4 scid={scid} '
        f'log_level=info video=true audio=false control=false '
        f'tunnel_forward=true cleanup=false '
        f'send_frame_meta=true send_dummy_byte=false '
        f'send_codec_meta=false send_device_meta=true'
    )
    # Send shell command
    send_adb_msg(server_sock, OPEN, 10, 0, f'shell:{server_cmd}\0'.encode())
    cmd, arg0, arg1, payload = recv_adb_msg(server_sock)
    if cmd != OKAY:
        print(f'  ✗ Server OPEN failed: 0x{cmd:08x}')
        return
    server_remote_id = arg0
    print(f'  → server 命令已发送, remote_id={server_remote_id}')

    # Drain server output in background
    def drain_server():
        try:
            while True:
                cmd, arg0, arg1, payload = recv_adb_msg(server_sock)
                if cmd == WRTE:
                    text = payload.decode('utf-8', errors='replace').strip()
                    if text:
                        print(f'  [server] {text}')
                    send_adb_msg(server_sock, OKAY, 10, arg0)
                elif cmd == CLSE:
                    break
        except:
            pass
    
    import threading
    drain_thread = threading.Thread(target=drain_server, daemon=True)
    drain_thread.start()

    # Wait for server to start
    print('  → 等待 server 启动...')
    time.sleep(2)

    # Step 6: Connect to abstract socket
    print('⑥ 连接 abstract socket...')
    video_sock = None
    for attempt in range(1, 4):
        try:
            video_sock = adb_connect(host, port)
            remote_id = adb_open_abstract(video_sock, socket_name, local_id=20)
            print(f'  ✓ 连接成功 (attempt {attempt}), remote_id={remote_id}')
            break
        except Exception as e:
            print(f'  → attempt {attempt}: {e}')
            if video_sock:
                video_sock.close()
                video_sock = None
            time.sleep(1)

    if video_sock is None:
        print('  ✗ 无法连接 abstract socket')
        return

    # Step 7: Read video stream and parse SPS
    print('⑦ 读取视频流，解析 SPS...')
    reader = {'sock': video_sock, 'buf': b'', 'local_id': 20}

    try:
        # Read device name (64 bytes)
        device_name_raw = read_exact(reader, 64)
        device_name = device_name_raw.decode('ascii', errors='replace').strip('\x00').strip()
        print(f'  → device: {device_name}')

        # Read frames
        frame_count = 0
        sps_found = 0
        resolutions = []

        while frame_count < 200:  # Read up to 200 frames
            pts_bytes = read_exact(reader, 8)
            pts = struct.unpack('>q', pts_bytes)[0]
            size_bytes = read_exact(reader, 4)
            frame_size = struct.unpack('>I', size_bytes)[0]

            if frame_size == 0 or frame_size > 10 * 1024 * 1024:
                print(f'  ⚠ 异常帧大小: {frame_size}')
                continue

            frame_data = read_exact(reader, frame_size)
            frame_count += 1

            # Parse NAL units for SPS
            for nal_type, nal_data in find_nal_units(frame_data):
                if nal_type == 7:  # SPS
                    sps_found += 1
                    result = parse_sps(nal_data)
                    if result:
                        w, h = result
                        resolutions.append((w, h))
                        marker = ''
                        if w != wm_w or h != wm_h:
                            marker = ' ⚠ 与 wm size 不一致!'
                        print(f'  → SPS #{sps_found}: {w}x{h}{marker}')
                    else:
                        print(f'  → SPS #{sps_found}: 解析失败')

            if frame_count <= 5 or frame_count % 50 == 0:
                first4 = frame_data[:4].hex(' ') if len(frame_data) >= 4 else '(短)'
                print(f'  → 帧 #{frame_count}: {frame_size}B first4={first4}')

    except KeyboardInterrupt:
        print('\n  中断')
    except Exception as e:
        print(f'  ✗ 错误: {e}')
    finally:
        video_sock.close()
        server_sock.close()

    # Summary
    print()
    print('=== 结果汇总 ===')
    print(f'wm size:        {wm_w}x{wm_h}')
    print(f'帧数:           {frame_count}')
    print(f'SPS 检测次数:    {sps_found}')
    if resolutions:
        unique = list(set(resolutions))
        print(f'SPS 分辨率:      {unique}')
        if unique[0] == (wm_w, wm_h):
            print('✓ SPS 与 wm size 一致')
        else:
            print('⚠ SPS 与 wm size 不一致，需要动态适配')
    else:
        print('⚠ 未检测到 SPS')

if __name__ == '__main__':
    main()
