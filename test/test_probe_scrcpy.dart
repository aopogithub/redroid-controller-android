import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

Future<void> main() async {
  const host = '192.168.101.188';
  const port = 5555;
  const socketName = 'scrcpy';
  const videoPort = 19876;

  print('=== Probe v2: full dump ===\n');

  int crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final b in data) { crc ^= b; for (var i = 0; i < 8; i++) { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1; } }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  Future<(Socket, Future<({int cmd, int arg0, int arg1, Uint8List data})> Function(), Future<void> Function(int, int, int, List<int>?))> makeConn() async {
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    final buf = BytesBuilder();
    final waiters = <Completer<void>>[];
    bool closed = false;
    s.listen((d) { buf.add(d); for (final c in waiters) { if (!c.isCompleted) c.complete(); } waiters.clear(); },
        onDone: () { closed = true; }, onError: (e) { closed = true; });
    Future<Uint8List> readExact(int n) async {
      while (buf.length < n) { if (closed) throw Exception('closed'); final c = Completer<void>(); waiters.add(c); await c.future.timeout(const Duration(seconds: 10)); }
      final all = buf.toBytes(); final r = Uint8List.fromList(all.sublist(0, n)); buf.clear(); if (all.length > n) buf.add(all.sublist(n)); return r;
    }
    Future<void> sendMsg(int cmd, int a0, int a1, List<int>? data) async {
      final d = data ?? Uint8List(0); final h = ByteData(24);
      h.setUint32(0, cmd, Endian.little); h.setUint32(4, a0, Endian.little); h.setUint32(8, a1, Endian.little);
      h.setUint32(12, d.length, Endian.little); h.setUint32(16, crc32(d), Endian.little); h.setUint32(20, cmd ^ 0xFFFFFFFF, Endian.little);
      s.add(h.buffer.asUint8List()); if (d.isNotEmpty) s.add(d); await s.flush();
    }
    Future<({int cmd, int arg0, int arg1, Uint8List data})> recvMsg() async {
      final hdr = await readExact(24); final bd = hdr.buffer.asByteData();
      return (cmd: bd.getUint32(0, Endian.little), arg0: bd.getUint32(4, Endian.little), arg1: bd.getUint32(8, Endian.little),
          data: bd.getUint32(12, Endian.little) > 0 ? await readExact(bd.getUint32(12, Endian.little)) : Uint8List(0));
    }
    final features = 'host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,apex,abb,fixed_push_symlink_timestamp,abb_exec,remount_shell,track_app,sendrecv_v2,sendrecv_v2_brotli,sendrecv_v2_lz4,sendrecv_v2_zstd,sendrecv_v2_dry_run_send,openscreen_mdns';
    await sendMsg(0x4e584e43, 0x01000001, 4096, utf8.encode('$features\x00'));
    final cnxn = await recvMsg(); if (cnxn.cmd != 0x4e584e43) throw Exception('CNXN failed');
    return (s, recvMsg, sendMsg);
  }

  String cn(int c) => String.fromCharCodes([c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, (c >> 24) & 0xFF]);

  // Forward
  print('[1] Forward...');
  { final (s, recv, send) = await makeConn();
    await send(0x4e45504f, 100, 0, utf8.encode('forward:tcp:$videoPort;localabstract:$socketName\x00'));
    final r = await recv(); print('  ${cn(r.cmd)}');
    if (r.cmd == 0x45545257) { print('  data: ${utf8.decode(r.data, allowMalformed: true).trim()}'); await send(0x59414b4f, 100, r.arg0, null); }
    await send(0x45534c43, 100, r.arg0, null); try { await recv(); } catch (_) {} s.destroy(); }
  await Future.delayed(const Duration(seconds: 1));

  // Kill old + start new
  print('\n[2] Start server...');
  { final (s, recv, send) = await makeConn();
    await send(0x4e45504f, 1, 0, utf8.encode('shell:kill \$(pgrep -f scrcpy) 2>/dev/null\n'));
    final ok = await recv();
    if (ok.cmd == 0x59414b4f) { while (true) { final m = await recv(); if (m.cmd == 0x45545257) await send(0x59414b4f, 1, m.arg0, null); else if (m.cmd == 0x45534c43) break; } }
    await send(0x45534c43, 1, ok.arg0, null); try { await recv(); } catch (_) {}
    await Future.delayed(const Duration(seconds: 1));
    final cmd = 'CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 2.6.1 scid=-1 log_level=info video=true audio=false control=false tunnel_forward=true cleanup=false send_frame_meta=true send_dummy_byte=true send_codec_meta=false send_device_meta=true\n';
    await send(0x4e45504f, 2, 0, utf8.encode('shell:$cmd'));
    final ok2 = await recv(); print('  ${cn(ok2.cmd)}');
    if (ok2.cmd == 0x59414b4f) { for (var i = 0; i < 20; i++) { try { final m = await recv().timeout(const Duration(seconds: 2)); if (m.cmd == 0x45545257) { final t = utf8.decode(m.data, allowMalformed: true).trim(); if (t.isNotEmpty) print('  [srv] $t'); await send(0x59414b4f, 2, m.arg0, null); } } catch (_) { break; } } }
    print('  (keeping alive)'); }
  await Future.delayed(const Duration(seconds: 3));

  // Connect and read ALL data
  print('\n[3] Connect localhost:$videoPort...');
  try {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, videoPort, timeout: const Duration(seconds: 5));
    print('  ✓ Connected');
    final reader = _SocketReader(s);

    // Read 2000 bytes
    print('  Reading 2000 bytes...');
    final data = await reader.readExact(2000);
    print('  Got ${data.length} bytes\n');

    // Dump
    for (var i = 0; i < data.length; i += 16) {
      final end = (i + 16).clamp(0, data.length);
      final chunk = data.sublist(i, end);
      final hex = chunk.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      final ascii = String.fromCharCodes(chunk.map((b) => b >= 32 && b < 127 ? b : 46));
      print('  ${i.toRadixString(16).padLeft(4, '0')}: $hex  $ascii');
    }

    // Analyze header
    final name = String.fromCharCodes(data.sublist(0, 64)).trimRight();
    print('\n  Device name (bytes 0-63): "$name"');
    final codecId = data.buffer.asByteData().getUint32(64, Endian.little);
    final width = data.buffer.asByteData().getUint32(68, Endian.little);
    print('  Codec ID (bytes 64-67): $codecId');
    print('  Width (bytes 68-71): $width');

    // Find NAL
    for (var i = 72; i < data.length - 4; i++) {
      if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1) {
        final nalType = data[i+4] & 0x1F;
        final nalName = {1: 'P', 5: 'IDR', 6: 'SEI', 7: 'SPS', 8: 'PPS'}[nalType] ?? '?';
        print('  NAL at offset $i: type=$nalType ($nalName)');
        break;
      }
    }

    s.destroy();
  } catch (e) {
    print('  ✗ FAILED: $e');
  }
  print('\nDone!');
}

class _SocketReader {
  final Socket socket;
  final List<int> _buffer = [];
  Completer<void>? _waiter;
  _SocketReader(this.socket) { socket.listen((data) { _buffer.addAll(data); _waiter?.complete(); _waiter = null; }); }
  Future<Uint8List> readExact(int n) async {
    while (_buffer.length < n) { _waiter = Completer<void>(); await _waiter!.future.timeout(const Duration(seconds: 10)); }
    final r = Uint8List.fromList(_buffer.sublist(0, n)); _buffer.removeRange(0, n); return r;
  }
}
