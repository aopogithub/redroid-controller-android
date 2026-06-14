import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

Future<void> main() async {
  const host = '192.168.101.188';
  const port = 5555;

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
    await sendMsg(0x4e584e43, 0x01000001, 4096, utf8.encode('host::features=shell_v2,cmd\x00'));
    final cnxn = await recvMsg(); if (cnxn.cmd != 0x4e584e43) throw Exception('CNXN failed');
    return (s, recvMsg, sendMsg);
  }

  String cn(int c) => String.fromCharCodes([c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, (c >> 24) & 0xFF]);

  // Kill old
  print('=== Kill old ===');
  { final (s, recv, send) = await makeConn();
    await send(0x4e45504f, 1, 0, utf8.encode('shell:pkill -f scrcpy 2>/dev/null; echo done\n'));
    final ok = await recv();
    if (ok.cmd == 0x59414b4f) { while (true) { final m = await recv(); if (m.cmd == 0x45545257) await send(0x59414b4f, 1, m.arg0, null); else if (m.cmd == 0x45534c43) break; } }
    await send(0x45534c43, 1, ok.arg0, null); s.destroy(); }
  await Future.delayed(const Duration(seconds: 1));

  // Test multiple parameter combos
  for (final params in [
    {'meta': 'false', 'frame': 'false', 'desc': 'device_meta=false frame_meta=false'},
    {'meta': 'true',  'frame': 'false', 'desc': 'device_meta=true  frame_meta=false'},
    {'meta': 'true',  'frame': 'true',  'desc': 'device_meta=true  frame_meta=true'},
  ]) {
    print('\n=== ${params['desc']} ===');
    final (sSrv, recvSrv, sendSrv) = await makeConn();
    final cmd = 'CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 2.6.1 scid=-1 log_level=info video=true audio=false control=false tunnel_forward=true cleanup=false send_frame_meta=${params['frame']} send_dummy_byte=false send_codec_meta=false send_device_meta=${params['meta']}\n';
    print('cmd: $cmd');
    await sendSrv(0x4e45504f, 1, 0, utf8.encode('shell:$cmd'));
    final okSrv = await recvSrv();
    print('OPEN: ${cn(okSrv.cmd)}');

    // Read server output 3s
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 3000) {
      try { final m = await recvSrv().timeout(const Duration(milliseconds: 300));
        if (m.cmd == 0x45545257) { await sendSrv(0x59414b4f, 1, m.arg0, null); }
        else if (m.cmd == 0x45534c43) break;
      } catch (_) {}
    }

    // Connect
    final (sVid, recvVid, sendVid) = await makeConn();
    await sendVid(0x4e45504f, 2, 0, utf8.encode('localabstract:scrcpy\x00'));
    final openResp = await recvVid();
    print('OPEN: ${cn(openResp.cmd)}');

    if (openResp.cmd == 0x59414b4f) {
      // Read first 3 WRTE messages, dump first 32 bytes each
      for (var i = 0; i < 3; i++) {
        try {
          final msg = await recvVid().timeout(const Duration(seconds: 3));
          if (msg.cmd == 0x45545257) {
            final p = msg.data;
            final hex = p.sublist(0, p.length > 32 ? 32 : p.length).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
            final ascii = String.fromCharCodes(p.sublist(0, p.length > 32 ? 32 : p.length).map((b) => b >= 32 && b < 127 ? b : 46));
            print('  WRTE[$i]: ${p.length}B hex=$hex ascii=$ascii');
            await sendVid(0x59414b4f, openResp.arg1, msg.arg0, null);
          } else { print('  msg[$i]: ${cn(msg.cmd)}'); break; }
        } catch (e) { print('  msg[$i]: timeout'); break; }
      }
    }

    await sendVid(0x45534c43, 2, openResp.arg0, null);
    sVid.destroy();
    sSrv.destroy();
    await Future.delayed(const Duration(seconds: 1));
  }
  print('\nDone!');
}
