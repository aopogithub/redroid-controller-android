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
    final features = 'host::features=shell_v2,cmd';
    await sendMsg(0x4e584e43, 0x01000001, 4096, utf8.encode('$features\x00'));
    final cnxn = await recvMsg(); if (cnxn.cmd != 0x4e584e43) throw Exception('CNXN failed');
    return (s, recvMsg, sendMsg);
  }

  String cn(int c) => String.fromCharCodes([c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, (c >> 24) & 0xFF]);

  Future<String> shell(String cmd) async {
    final (s, recv, send) = await makeConn();
    await send(0x4e45504f, 1, 0, utf8.encode('shell:$cmd\n'));
    final ok = await recv();
    if (ok.cmd != 0x59414b4f) { s.destroy(); return 'OPEN failed: ${cn(ok.cmd)}'; }
    final out = StringBuffer();
    while (true) {
      final msg = await recv();
      if (msg.cmd == 0x45545257) { out.write(utf8.decode(msg.data, allowMalformed: true)); await send(0x59414b4f, 1, msg.arg0, null); }
      else if (msg.cmd == 0x45534c43) break;
    }
    await send(0x45534c43, 1, ok.arg0, null);
    s.destroy();
    return out.toString().trim();
  }

  // Kill old server
  print('=== 1. 清理 ===');
  await shell('kill \$(pgrep -f scrcpy) 2>/dev/null');
  await Future.delayed(const Duration(seconds: 1));

  // Check socket before forward
  print('=== 2. forward 前检查 socket ===');
  var unix = await shell('cat /proc/net/unix | grep scrcpy');
  print('socket: ${unix.isEmpty ? "无" : unix}');

  // Send forward command
  print('\n=== 3. 发送 forward 命令 ===');
  {
    final (s, recv, send) = await makeConn();
    await send(0x4e45504f, 100, 0, utf8.encode('forward:tcp:19876;localabstract:scrcpy\x00'));
    final resp = await recv();
    print('forward resp: ${cn(resp.cmd)}');
    if (resp.cmd == 0x45545257) {
      print('  data: ${utf8.decode(resp.data, allowMalformed: true).trim()}');
      await send(0x59414b4f, 100, resp.arg0, null);
      final resp2 = await recv();
      print('  next: ${cn(resp2.cmd)}');
      await send(0x45534c43, 100, resp2.arg0, null);
    } else if (resp.cmd == 0x59414b4f) {
      print('  OKAY! forward 成功');
      await send(0x45534c43, 100, resp.arg0, null);
    } else if (resp.cmd == 0x45534c43) {
      print('  CLSE — forward 被拒绝');
    }
    try { await recv(); } catch (_) {}
    s.destroy();
  }

  // Check socket after forward
  print('\n=== 4. forward 后检查 socket ===');
  unix = await shell('cat /proc/net/unix | grep scrcpy');
  print('socket: ${unix.isEmpty ? "无" : unix}');

  // Start server with tunnel_forward=true
  print('\n=== 5. 启动 server (tunnel_forward=true) ===');
  final (s2, recv2, send2) = await makeConn();
  await send2(0x4e45504f, 1, 0, utf8.encode('shell:CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 2.6.1 scid=-1 log_level=debug video=true audio=false control=false tunnel_forward=true cleanup=false send_frame_meta=true send_dummy_byte=false send_codec_meta=false send_device_meta=true\n'));
  final ok2 = await recv2();
  print('server OPEN: ${cn(ok2.cmd)}');

  final serverOut = StringBuffer();
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < 5000) {
    try {
      final msg = await recv2().timeout(const Duration(milliseconds: 500));
      if (msg.cmd == 0x45545257) {
        serverOut.write(utf8.decode(msg.data, allowMalformed: true));
        await send2(0x59414b4f, 1, msg.arg0, null);
      } else if (msg.cmd == 0x45534c43) { serverOut.write('[CLSE]'); break; }
    } catch (_) {}
  }
  print('server output:\n${serverOut.toString()}');

  // Check socket after server start
  print('\n=== 6. server 启动后检查 socket ===');
  unix = await shell('cat /proc/net/unix | grep scrcpy');
  print('socket: ${unix.isEmpty ? "无" : unix}');

  // Try OPEN localabstract:scrcpy
  print('\n=== 7. 尝试 OPEN localabstract:scrcpy ===');
  final (s3, recv3, send3) = await makeConn();
  await send3(0x4e45504f, 2, 0, utf8.encode('localabstract:scrcpy\x00'));
  final openResp = await recv3();
  print('resp: ${cn(openResp.cmd)} arg0=${openResp.arg0} arg1=${openResp.arg1}');

  if (openResp.cmd == 0x59414b4f) {
    print('✓ 连接成功!');
  } else if (openResp.cmd == 0x59414b4f) {
    print('✓ 连接成功! 读取数据...');
    try {
      final first = await recv3().timeout(const Duration(seconds: 3));
      print('  first: ${cn(first.cmd)} ${first.data.length}B');
      if (first.data.length >= 72) {
        final name = String.fromCharCodes(first.data.sublist(0, 64)).trimRight();
        print('  device: $name');
      }
    } catch (e) { print('  超时: $e'); }
  } else if (openResp.cmd == 0x45534c43) {
    print('✗ CLSE');
  } else {
    print('✗ ${cn(openResp.cmd)}');
  }

  await send3(0x45534c43, 2, openResp.arg0, null);
  s3.destroy();
  s2.destroy();
  print('\nDone!');
}
