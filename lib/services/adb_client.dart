import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal ADB protocol client. Connects directly to adbd over TCP.
class AdbClient {
  Socket? _socket;
  int _maxPayload = 4096;
  bool _connected = false;
  String _host = '';
  int _port = 5555;
  int _nextLocalId = 1;

  final _buffer = BytesBuilder();
  final _waiters = <Completer<void>>[];
  bool _socketClosed = false;

  static const int cmdCnxn = 0x4e584e43;
  static const int cmdOpen = 0x4e45504f;
  static const int cmdOkay = 0x59414b4f;
  static const int cmdClse = 0x45534c43;
  static const int cmdWrte = 0x45545257;
  static const int cmdAuth = 0x48545541;

  bool get isConnected => _connected;

  // ── Connection ──

  Future<void> connect(String host, int port) async {
    _host = host;
    _port = port;
    _socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));

    _socket!.listen(
      (data) {
        _buffer.add(data);
        for (final c in _waiters) {
          if (!c.isCompleted) c.complete();
        }
        _waiters.clear();
      },
      onError: (e) {
        _socketClosed = true;
        for (final c in _waiters) {
          if (!c.isCompleted) c.completeError(e);
        }
        _waiters.clear();
      },
      onDone: () {
        _socketClosed = true;
        for (final c in _waiters) {
          if (!c.isCompleted) c.completeError(Exception('Socket closed'));
        }
        _waiters.clear();
      },
    );

    final features = 'host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,apex,abb,fixed_push_symlink_timestamp,abb_exec,remount_shell,track_app,sendrecv_v2,sendrecv_v2_brotli,sendrecv_v2_lz4,sendrecv_v2_zstd,sendrecv_v2_dry_run_send,openscreen_mdns';
    await sendMessage(cmdCnxn, 0x01000001, _maxPayload, utf8.encode('$features\x00'));

    final resp = await readMessage();
    if (resp.cmd != cmdCnxn) throw Exception('CNXN failed: ${cmdName(resp.cmd)}');
    _maxPayload = resp.arg1;
    _connected = true;
  }

  void disconnect() {
    _socket?.destroy();
    _socket = null;
    _connected = false;
    _socketClosed = true;
    for (final c in _waiters) {
      if (!c.isCompleted) c.completeError(Exception('Disconnected'));
    }
    _waiters.clear();
  }

  // ── Service helpers ──

  Future<({int localId, int remoteId})> _openService(String service) async {
    final localId = _nextLocalId++;
    await sendMessage(cmdOpen, localId, 0, utf8.encode('$service\x00'));
    final resp = await readMessage();
    if (resp.cmd != cmdOkay) {
      throw Exception('OPEN $service failed: ${cmdName(resp.cmd)}');
    }
    return (localId: localId, remoteId: resp.arg0);
  }

  void _ensureConnected() {
    if (!_connected) throw StateError('Not connected');
  }

  // ── Shell ──

  /// Execute a shell command and return trimmed output.
  /// Uses a separate connection to keep the main one clean.
  Future<String> shellExec(String command) async {
    _ensureConnected();
    final tmp = AdbClient();
    await tmp.connect(_host, _port);
    try {
      return await tmp._shellExecInternal(command);
    } finally {
      tmp.disconnect();
    }
  }

  Future<String> _shellExecInternal(String command) async {
    final localId = _nextLocalId++;
    await sendMessage(cmdOpen, localId, 0, utf8.encode('shell:$command\x00'));
    final openResp = await readMessage();
    if (openResp.cmd != cmdOkay) {
      throw Exception('Shell OPEN failed: ${cmdName(openResp.cmd)}');
    }

    final output = BytesBuilder();
    while (true) {
      final msg = await readMessage();
      if (msg.cmd == cmdWrte) {
        output.add(msg.data);
        await sendMessage(cmdOkay, localId, msg.arg0, null);
      } else if (msg.cmd == cmdClse) {
        break;
      }
    }
    await sendMessage(cmdClse, localId, openResp.arg0, null);
    try { await readMessage(); } catch (_) {}
    return utf8.decode(output.toBytes(), allowMalformed: true).trim();
  }

  // ── Push ──

  /// Push [data] to [remotePath] on device.
  /// Uses a separate connection per operation.
  Future<void> pushFile(List<int> data, String remotePath) async {
    _ensureConnected();
    final tmp = AdbClient();
    await tmp.connect(_host, _port);
    try {
      await tmp._pushFileInternal(data, remotePath);
    } finally {
      tmp.disconnect();
    }
  }

  Future<void> _pushFileInternal(List<int> data, String remotePath) async {
    final (:localId, :remoteId) = await _openService('sync:');

    Future<void> wrteSync(List<int> syncPayload) async {
      await sendMessage(cmdWrte, localId, remoteId, Uint8List.fromList(syncPayload));
      while (true) {
        final resp = await readMessage();
        if (resp.cmd == cmdOkay) return;
        if (resp.cmd == cmdWrte) {
          await sendMessage(cmdOkay, localId, resp.arg0, null);
        } else if (resp.cmd == cmdClse) {
          throw Exception('Stream closed unexpectedly');
        } else {
          throw Exception('Unexpected: ${cmdName(resp.cmd)}');
        }
      }
    }

    try {
      // SEND v1: path,mode\0
      const fileMode = 33188; // 0o100644
      final sendPayload = Uint8List.fromList([...utf8.encode('$remotePath,$fileMode'), 0]);
      await wrteSync(_syncRaw('SEND', sendPayload));

      // DATA chunks
      var offset = 0;
      while (offset < data.length) {
        final end = (offset + _maxPayload - 8).clamp(0, data.length);
        await wrteSync(_syncData(data.sublist(offset, end)));
        offset = end;
      }

      // DONE
      final donePayload = ByteData(4)..setUint32(0, 0, Endian.little);
      await wrteSync(_syncRaw('DONE', donePayload.buffer.asUint8List()));
    } finally {
      await sendMessage(cmdClse, localId, remoteId, null);
      try { await readMessage(); } catch (_) {}
    }
  }

  // ── Forward ──

  Future<void> forward(String hostSpec, String deviceSpec) async {
    _ensureConnected();
    final (:localId, :remoteId) = await _openService('reverse:forward=$hostSpec;$deviceSpec');
    final resp = await readMessage();
    if (resp.cmd == cmdWrte) {
      final text = utf8.decode(resp.data, allowMalformed: true).trim();
      await sendMessage(cmdOkay, localId, resp.arg0, null);
      if (text.isNotEmpty) throw Exception('Forward failed: $text');
    }
    await sendMessage(cmdClse, localId, remoteId, null);
    try { await readMessage(); } catch (_) {}
  }

  /// Execute shell command on existing connection (no reconnect).
  Future<String> shell(String command) async {
    _ensureConnected();
    return await _shellExecInternal(command);
  }

  /// Push file on existing connection (no reconnect).
  Future<void> push(List<int> data, String remotePath) async {
    _ensureConnected();
    await _pushFileInternal(data, remotePath);
  }

  // ── Static convenience ──

  static Future<String> execShell(String host, int port, String command) async {
    final c = AdbClient();
    await c.connect(host, port);
    try {
      return await c.shellExec(command);
    } finally {
      c.disconnect();
    }
  }

  static Future<void> pushFileTo(String host, int port, List<int> data, String remotePath) async {
    final c = AdbClient();
    await c.connect(host, port);
    try {
      await c.pushFile(data, remotePath);
    } finally {
      c.disconnect();
    }
  }

  // ── Protocol ──

  Future<void> sendMessage(int cmd, int arg0, int arg1, List<int>? data) async {
    final d = data ?? Uint8List(0);
    final header = Uint8List(24);
    final bd = header.buffer.asByteData();
    bd.setUint32(0, cmd, Endian.little);
    bd.setUint32(4, arg0, Endian.little);
    bd.setUint32(8, arg1, Endian.little);
    bd.setUint32(12, d.length, Endian.little);
    bd.setUint32(16, _crc32(d), Endian.little);
    bd.setUint32(20, cmd ^ 0xFFFFFFFF, Endian.little);
    _socket!.add(header);
    if (d.isNotEmpty) _socket!.add(d);
    await _socket!.flush();
  }

  Future<AdbMessage> readMessage() async {
    final header = await _readExact(24);
    final bd = header.buffer.asByteData();
    final cmd = bd.getUint32(0, Endian.little);
    final arg0 = bd.getUint32(4, Endian.little);
    final arg1 = bd.getUint32(8, Endian.little);
    final dataLen = bd.getUint32(12, Endian.little);
    final data = dataLen > 0 ? await _readExact(dataLen) : Uint8List(0);
    if (cmd == cmdAuth) {
      throw Exception('ADB auth required');
    }
    return AdbMessage(cmd: cmd, arg0: arg0, arg1: arg1, data: data);
  }

  Future<Uint8List> _readExact(int count) async {
    while (_buffer.length < count) {
      if (_socketClosed) throw Exception('Socket closed');
      final c = Completer<void>();
      _waiters.add(c);
      await c.future.timeout(const Duration(seconds: 10), onTimeout: () {
        _waiters.remove(c);
        throw TimeoutException('Read timeout');
      });
    }
    return _take(count);
  }

  Uint8List _take(int count) {
    final all = _buffer.toBytes();
    final result = Uint8List.fromList(all.sublist(0, count));
    _buffer.clear();
    if (all.length > count) _buffer.add(all.sublist(count));
    return result;
  }

  // ── Sync protocol ──

  static Uint8List _syncRaw(String name, List<int> data) {
    final nameBytes = ascii.encode(name);
    final result = Uint8List(8 + data.length);
    var nameVal = 0;
    for (var i = 0; i < nameBytes.length; i++) {
      nameVal |= nameBytes[i] << (i * 8);
    }
    result.buffer.asByteData().setUint32(0, nameVal, Endian.little);
    result.buffer.asByteData().setUint32(4, data.length, Endian.little);
    result.setRange(8, 8 + data.length, data);
    return result;
  }

  static Uint8List _syncData(List<int> data) {
    final result = Uint8List(8 + data.length);
    final bd = result.buffer.asByteData();
    bd.setUint32(0, 0x41544144, Endian.little); // DATA
    bd.setUint32(4, data.length, Endian.little);
    result.setRange(8, 8 + data.length, data);
    return result;
  }

  static int _crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static String cmdName(int cmd) {
    return String.fromCharCodes([cmd & 0xFF, (cmd >> 8) & 0xFF, (cmd >> 16) & 0xFF, (cmd >> 24) & 0xFF]);
  }
}

/// ADB message wrapper.
class AdbMessage {
  final int cmd;
  final int arg0;
  final int arg1;
  final Uint8List data;
  AdbMessage({required this.cmd, required this.arg0, required this.arg1, required this.data});
  String get command => AdbClient.cmdName(cmd);
  @override
  String toString() => 'AdbMsg($command, arg0=$arg0, arg1=$arg1, dataLen=${data.length})';
}
