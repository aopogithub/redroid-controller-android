import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

/// Test scrcpy binary control protocol (touch events)
Future<void> main() async {
  const host = '192.168.101.188';
  const port = 5555;
  const socketName = 'scrcpy';

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

  // Kill + start server with control=true
  print('=== 1. Kill + start server (control=true) ===');
  { final (s, recv, send) = await makeConn();
    await send(0x4e45504f, 1, 0, utf8.encode('shell:pkill -f scrcpy 2>/dev/null; echo done\n'));
    final ok = await recv();
    if (ok.cmd == 0x59414b4f) { while (true) { final m = await recv(); if (m.cmd == 0x45545257) await send(0x59414b4f, 1, m.arg0, null); else if (m.cmd == 0x45534c43) break; } }
    await send(0x45534c43, 1, ok.arg0, null); s.destroy(); }
  await Future.delayed(const Duration(seconds: 1));

  final (sSrv, recvSrv, sendSrv) = await makeConn();
  await sendSrv(0x4e45504f, 1, 0, utf8.encode('shell:CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 2.6.1 scid=-1 log_level=info video=true audio=false control=true tunnel_forward=true cleanup=false send_frame_meta=false send_dummy_byte=false send_codec_meta=false send_device_meta=false\n'));
  final okSrv = await recvSrv();
  print('server OPEN: ${cn(okSrv.cmd)}');
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < 3000) {
    try { final m = await recvSrv().timeout(const Duration(milliseconds: 300));
      if (m.cmd == 0x45545257) { await sendSrv(0x59414b4f, 1, m.arg0, null); }
      else if (m.cmd == 0x45534c43) break;
    } catch (_) {}
  }
  await Future.delayed(const Duration(seconds: 2));

  // Connect video
  print('\n=== 2. Connect video ===');
  final (sVid, recvVid, sendVid) = await makeConn();
  await sendVid(0x4e45504f, 2, 0, utf8.encode('localabstract:$socketName\x00'));
  final vidOpen = await recvVid();
  print('video OPEN: ${cn(vidOpen.cmd)} arg0=${vidOpen.arg0} arg1=${vidOpen.arg1}');
  if (vidOpen.cmd != 0x59414b4f) { print('FAIL'); return; }

  // Connect control (second connection to same socket)
  print('\n=== 3. Connect control ===');
  final (sCtrl, recvCtrl, sendCtrl) = await makeConn();
  await sendCtrl(0x4e45504f, 3, 0, utf8.encode('localabstract:$socketName\x00'));
  final ctrlOpen = await recvCtrl();
  print('control OPEN: ${cn(ctrlOpen.cmd)} arg0=${ctrlOpen.arg0} arg1=${ctrlOpen.arg1}');
  if (ctrlOpen.cmd != 0x59414b4f) { print('FAIL'); return; }
  final remoteId = ctrlOpen.arg1;
  print('remote_id=$remoteId');

  // Start background reader for control OKAY responses
  final ctrlReaderActive = true;
  () async {
    while (ctrlReaderActive) {
      try {
        final m = await recvCtrl().timeout(const Duration(seconds: 5));
        if (m.cmd == 0x45534c43) { print('  ctrl: CLSE'); break; }
        // OKAY — just drain
      } catch (_) {}
    }
  }();

  // Send touch DOWN at (360, 640) — center of 720x1280
  print('\n=== 4. Send touch DOWN ===');
  {
    final payload = ByteData(31);
    payload.setUint8(0, 0); // ACTION_DOWN
    payload.setInt64(1, 0, Endian.big); // pointer_id
    payload.setInt32(9, 360, Endian.big); // x
    payload.setInt32(13, 640, Endian.big); // y
    payload.setInt16(17, 720, Endian.big); // width
    payload.setInt16(19, 1280, Endian.big); // height
    payload.setUint16(21, 0xFFFF, Endian.big); // pressure
    payload.setInt32(23, 1, Endian.big); // action_button
    payload.setInt32(27, 0, Endian.big); // buttons

    // Type byte (2 = INJECT_TOUCH_EVENT) + payload
    final msg = BytesBuilder();
    msg.add([2]); // type
    msg.add(payload.buffer.asUint8List());

    await sendCtrl(0x45545257, 3, remoteId, msg.toBytes());
    print('  sent ${msg.toBytes().length} bytes');
  }

  await Future.delayed(const Duration(milliseconds: 100));

  // Send touch UP
  print('\n=== 5. Send touch UP ===');
  {
    final payload = ByteData(31);
    payload.setUint8(0, 1); // ACTION_UP
    payload.setInt64(1, 0, Endian.big);
    payload.setInt32(9, 360, Endian.big);
    payload.setInt32(13, 640, Endian.big);
    payload.setInt16(17, 720, Endian.big);
    payload.setInt16(19, 1280, Endian.big);
    payload.setUint16(21, 0, Endian.big); // pressure=0 for UP
    payload.setInt32(23, 1, Endian.big);
    payload.setInt32(27, 0, Endian.big);

    final msg = BytesBuilder();
    msg.add([2]); // type
    msg.add(payload.buffer.asUint8List());

    await sendCtrl(0x45545257, 3, remoteId, msg.toBytes());
    print('  sent ${msg.toBytes().length} bytes');
  }

  await Future.delayed(const Duration(seconds: 1));

  // Cleanup
  await sendCtrl(0x45534c43, 3, remoteId, null);
  await sendVid(0x45534c43, 2, vidOpen.arg0, null);
  sCtrl.destroy();
  sVid.destroy();
  sSrv.destroy();
  print('\nDone! Check if touch was registered on device.');
}
