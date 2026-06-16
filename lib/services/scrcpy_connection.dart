import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'adb_client.dart';
import 'sps_parser.dart';

enum ScrcpyState { disconnected, connecting, connected, error }

class DeviceInfo {
  final String deviceName;
  final int videoWidth;
  final int videoHeight;
  DeviceInfo({required this.deviceName, required this.videoWidth, required this.videoHeight});
}

/// Helper to read exact bytes from a Socket stream
class _SocketReader {
  final Socket socket;
  final List<int> _buffer = [];
  Completer<void>? _waiter;
  bool _closed = false;
  StreamSubscription<List<int>>? _subscription;

  _SocketReader(this.socket) {
    _subscription = socket.listen(
      (data) {
        _buffer.addAll(data);
        _waiter?.complete();
        _waiter = null;
      },
      onDone: () {
        _closed = true;
        _waiter?.complete();
        _waiter = null;
      },
    );
  }

  Future<Uint8List> readExact(int n) async {
    while (_buffer.length < n) {
      if (_closed && _buffer.isEmpty) throw Exception('Socket closed');
      _waiter = Completer<void>();
      await _waiter!.future.timeout(const Duration(seconds: 30));
    }
    final result = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return result;
  }

  Future<Uint8List> readRaw(int maxBytes) async {
    while (_buffer.isEmpty) {
      if (_closed) throw Exception('Socket closed');
      _waiter = Completer<void>();
      await _waiter!.future.timeout(const Duration(seconds: 30));
    }
    final n = _buffer.length < maxBytes ? _buffer.length : maxBytes;
    final result = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return result;
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}

class ScrcpyConnection with ChangeNotifier {
  static const CNXN_V = 0x4e584e43;
  static const OPEN_V  = 0x4e45504f;
  static const OKAY_V  = 0x59414b4f;
  static const FAIL_V  = 0x4c494146;
  static const WRTE_V  = 0x45545257;
  static const CLSE_V  = 0x45534c43;
  ScrcpyState _state = ScrcpyState.disconnected;
  DeviceInfo? _deviceInfo;
  String? _host;
  int _port = 5555;
  Socket? _controlSocket;
  StreamSubscription? _controlSub;
  int? _controlRemoteId;

  final _stateController = StreamController<ScrcpyState>.broadcast();
  final _deviceInfoController = StreamController<DeviceInfo>.broadcast();
  final _videoFrameController = StreamController<Uint8List>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _resolutionChangeController = StreamController<({int width, int height})>.broadcast();

  ScrcpyState get state => _state;
  DeviceInfo? get deviceInfo => _deviceInfo;
  Stream<ScrcpyState> get stateStream => _stateController.stream;
  Stream<DeviceInfo> get deviceInfoStream => _deviceInfoController.stream;
  Stream<Uint8List> get videoFrameStream => _videoFrameController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<({int width, int height})> get resolutionChangeStream => _resolutionChangeController.stream;

  void _log(String msg) => _errorController.add(msg);

  Future<void> connect({required String host, int port = 5555}) async {
    if (_state == ScrcpyState.connected || _state == ScrcpyState.connecting) return;
    _host = host;
    _port = port;
    _updateState(ScrcpyState.connecting);

    try {
      // Step 1: Write jar to local temp file
      _log('① 准备 scrcpy-server.jar ...');
      final jarData = await rootBundle.load('assets/scrcpy-server.jar');
      final tempDir = await getTemporaryDirectory();
      final jarFile = File('${tempDir.path}/scrcpy-server.jar');
      await jarFile.writeAsBytes(jarData.buffer.asUint8List());
      _log('  → 本地: ${jarFile.path} (${jarFile.lengthSync()} bytes)');

      const scid = -1;
      const socketName = 'scrcpy';
      _log('  → scid=$scid (default socket), socketName=$socketName');

      // Shared ADB connection for all setup operations
      final adb = AdbClient();
      await adb.connect(host, port);
      _log('  → ADB 已连接');

      int? queriedWidth, queriedHeight;

      try {
        // Step 2: Kill any existing scrcpy server
        await adb.shell('pkill -9 -f scrcpy 2>/dev/null')
            .timeout(const Duration(seconds: 2), onTimeout: () => '')
            .catchError((_) => '');
        await Future.delayed(const Duration(milliseconds: 200));

        // Step 3: Push jar (skip if same size already on device)
        _log('③ 检查 jar ...');
        final jarBytes = jarFile.readAsBytesSync();
        final jarSize = jarBytes.length;
        var needPush = true;
        try {
          final lsResult = await adb.shell('wc -c < /data/local/tmp/scrcpy-server.jar 2>/dev/null')
              .timeout(const Duration(seconds: 2), onTimeout: () => '');
          final remoteSize = int.tryParse(lsResult.trim());
          if (remoteSize == jarSize) {
            needPush = false;
            _log('  → 已存在 (${jarSize}B)，跳过推送');
          } else {
            _log('  → 大小不同 local=$jarSize remote=$remoteSize，需要推送');
          }
        } catch (e) {
          _log('  → 检查失败，推送: $e');
        }
        if (needPush) {
          _log('  → 推送 jar ($jarSize B) ...');
          await adb.push(jarBytes, '/data/local/tmp/scrcpy-server.jar');
          _log('  → 推送成功');
        }

        // Step 4: Query device resolution
        _log('④ 查询设备分辨率 ...');
        try {
          final wmSize = await adb.shell('wm size')
              .timeout(const Duration(seconds: 3), onTimeout: () => '');
          _log('  → wm size: ${wmSize.trim()}');
          final physicalMatch = RegExp(r'Physical size:\s*(\d+)x(\d+)').firstMatch(wmSize);
          if (physicalMatch != null) {
            queriedWidth = int.parse(physicalMatch.group(1)!);
            queriedHeight = int.parse(physicalMatch.group(2)!);
            _log('  → 设备分辨率: ${queriedWidth}x$queriedHeight');
          }
          final rotation = await adb.shell('dumpsys display | grep mCurrentOrientation')
              .timeout(const Duration(seconds: 3), onTimeout: () => '');
          _log('  → orientation: $rotation');
          if (rotation.contains('LANDSCAPE') || rotation.contains('mCurrentOrientation=1') || rotation.contains('mCurrentOrientation=3')) {
            final tmp = queriedWidth;
            queriedWidth = queriedHeight;
            queriedHeight = tmp;
            _log('  → 横屏，交换分辨率: ${queriedWidth}x$queriedHeight');
          }
        } catch (e) {
          _log('  → 查询分辨率失败: $e');
        }
        if (queriedWidth != null && queriedHeight != null) {
          _deviceInfo = DeviceInfo(deviceName: 'redroid', videoWidth: queriedWidth!, videoHeight: queriedHeight!);
          _deviceInfoController.add(_deviceInfo!);
          _log('  → DeviceInfo 已设置: ${queriedWidth}x$queriedHeight');
        }

        // Step 5: Start scrcpy server (separate connection, stays alive)
        _log('⑤ 启动 scrcpy server ...');
      } finally {
        // Close setup ADB connection
        adb.disconnect();
      }

      // Server uses its own ADB connection (stays open for server output)
      final serverSocket = await Socket.connect(host, port, timeout: const Duration(seconds: 10));
      final serverReader = _SocketReader(serverSocket);
      await _sendAdbMsg(serverSocket, CNXN_V, 0x01000001, 4096, utf8.encode('host::features=shell_v2,cmd\x00'));
      final serverCnxnResp = await _recvAdbMsg(serverReader);
      if (serverCnxnResp.cmd != CNXN_V) throw Exception('Server CNXN failed');

      final serverCmd = 'CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 4.0 scid=$scid log_level=info video=true audio=false control=true tunnel_forward=true cleanup=false send_frame_meta=true send_dummy_byte=false send_stream_meta=true send_device_meta=true max_fps=30 video_bit_rate=4000000';
      _log('  → shell: $serverCmd');
      await _sendAdbMsg(serverSocket, OPEN_V, 1, 0, utf8.encode('shell:$serverCmd\x00'));
      final serverOpenResp = await _recvAdbMsg(serverReader);
      if (serverOpenResp.cmd != OKAY_V) throw Exception('Server OPEN failed');
      _log('  → server 命令已发送');

      // Read server output in background
      _readServerOutput(serverReader, serverSocket);

      // Step 6: Connect to abstract socket via ADB protocol (with quick retry)
      _log('⑥ 连接 abstract socket ...');
      Socket? videoSocket;
      _SocketReader? videoReader;
      for (var attempt = 1; attempt <= 5; attempt++) {
        try {
          videoSocket = await Socket.connect(host, port, timeout: const Duration(seconds: 3));
          videoReader = _SocketReader(videoSocket);
          await _sendAdbMsg(videoSocket, CNXN_V, 0x01000001, 4096, utf8.encode('host::features=shell_v2,cmd\x00'));
          final cnxnResp = await _recvAdbMsg(videoReader);
          if (cnxnResp.cmd != CNXN_V) throw Exception('Video CNXN failed');

          await _sendAdbMsg(videoSocket, OPEN_V, 2, 0, utf8.encode('localabstract:$socketName\x00'));
          final openResp = await _recvAdbMsg(videoReader);
          if (openResp.cmd == OKAY_V) {
            _log('  ✓ 连接成功 (attempt $attempt)');
            break;
          }
          _log('  → attempt $attempt: ${openResp.cmd == CLSE_V ? "CLSE" : "0x${openResp.cmd.toRadixString(16)}"}');
          videoSocket.destroy();
          videoSocket = null;
          if (attempt < 5) await Future.delayed(const Duration(milliseconds: 500));
        } catch (e) {
          _log('  → attempt $attempt 错误: $e');
          videoSocket?.destroy();
          videoSocket = null;
          if (attempt < 5) await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      if (videoSocket == null || videoReader == null) {
        throw Exception('无法连接 abstract socket [$socketName]');
      }

      // Step 7: Open control connection
      _log('⑦ 连接 control socket ...');
      try {
        final ctrlSocket = await Socket.connect(host, port, timeout: const Duration(seconds: 10));
        final ctrlReader = _SocketReader(ctrlSocket);

        // ADB handshake
        await _sendAdbMsg(ctrlSocket, CNXN_V, 0x01000001, 4096, utf8.encode('host::features=shell_v2,cmd\x00'));
        final cnxnResp = await _recvAdbMsg(ctrlReader);
        if (cnxnResp.cmd != CNXN_V) throw Exception('Ctrl CNXN failed');

        // Open abstract socket
        await _sendAdbMsg(ctrlSocket, OPEN_V, 3, 0, utf8.encode('localabstract:$socketName\x00'));
        final openResp = await _recvAdbMsg(ctrlReader);
        if (openResp.cmd != OKAY_V) throw Exception('Ctrl OPEN failed');

        _controlSocket = ctrlSocket;
        _controlRemoteId = openResp.arg0;
        _log('  ✓ control 已连接 (remote_id=$_controlRemoteId)');
        _controlSub?.cancel();
        _controlSub = ctrlSocket.listen((_) {}, onError: (_) {}, onDone: () {});
      } catch (e) {
        _log('  ⚠ control 错误: $e');
      }

      // Step 8: Read video data
      _log('⑧ 读取视频数据...');
      _updateState(ScrcpyState.connected);
      _readVideoFramesFromAdb(videoReader, videoSocket, queriedWidth, queriedHeight);
    } catch (e) {
      String msg;
      if (e is PlatformException) {
        msg = '错误: ${e.message}\n${e.details ?? ''}';
      } else {
        msg = '错误: $e';
      }
      _log('✗ $msg');
      _updateState(ScrcpyState.error);
      disconnect();
    }
  }

  void _updateState(ScrcpyState s) { _state = s; _stateController.add(s); notifyListeners(); }

  // ---- ADB message helpers (class-level, use static consts) ----
  static Future<void> _sendAdbMsg(Socket s, int cmd, int arg0, int arg1, [List<int>? payload]) async {
    final len = payload?.length ?? 0;
    var crc = 0xFFFFFFFF;
    for (final byte in (payload ?? [])) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB88320 : 0);
      }
    }
    final checksum = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
    final magic = (cmd ^ 0xFFFFFFFF) & 0xFFFFFFFF;
    final header = ByteData(24);
    header.setUint32(0, cmd, Endian.little);
    header.setUint32(4, arg0, Endian.little);
    header.setUint32(8, arg1, Endian.little);
    header.setUint32(12, len, Endian.little);
    header.setUint32(16, checksum, Endian.little);
    header.setUint32(20, magic, Endian.little);
    s.add(header.buffer.asUint8List());
    if (payload != null && payload.isNotEmpty) s.add(payload);
    await s.flush();
  }

  static Future<({int cmd, int arg0, int arg1, Uint8List payload})> _recvAdbMsg(_SocketReader r) async {
    final header = await r.readExact(24);
    final bd = header.buffer.asByteData();
    final cmd = bd.getUint32(0, Endian.little);
    final arg0 = bd.getUint32(4, Endian.little);
    final arg1 = bd.getUint32(8, Endian.little);
    final len = bd.getUint32(12, Endian.little);
    final payload = len > 0 ? await r.readExact(len) : Uint8List(0);
    return (cmd: cmd, arg0: arg0, arg1: arg1, payload: payload);
  }

  /// Read video frames from scrcpy server (H.264 stream)
  /// Data arrives wrapped in ADB WRTE messages.
  void _readVideoFrames(_SocketReader reader, Socket socket) async {
    try {
      _log('  → _readVideoFrames 启动');
      // Buffer for accumulating payload data from WRTE messages
      final buf = BytesBuilder();
      var frameCount = 0;
      var wrteCount = 0;

      Future<Uint8List> ensureBytes(int n) async {
        while (buf.length < n) {
          // Read next ADB WRTE message
          final msg = await _recvAdbMsg(reader);
          if (msg.cmd == WRTE_V) {
            wrteCount++;
            if (wrteCount <= 3) {
              _log('  → WRTE[$wrteCount]: ${msg.payload.length}B, arg0=${msg.arg0} arg1=${msg.arg1}');
            }
            await _sendAdbMsg(socket, OKAY_V, msg.arg1, msg.arg0);
            buf.add(msg.payload);
          } else if (msg.cmd == CLSE_V) {
            throw Exception('Connection closed');
          } else {
            _log('  → unexpected msg: 0x${msg.cmd.toRadixString(16)}');
          }
        }
        final result = Uint8List.fromList(buf.toBytes().sublist(0, n));
        // Remove consumed bytes
        final remaining = buf.toBytes().sublist(n);
        buf.clear();
        buf.add(remaining);
        return result;
      }

      while (_state == ScrcpyState.connected) {
        // scrcpy v2 frame format: PTS (8 bytes BE) + frame_size (4 bytes BE) + data
        final ptsBytes = await ensureBytes(8);
        final pts = ptsBytes.buffer.asByteData().getInt64(0, Endian.big);

        final sizeBytes = await ensureBytes(4);
        final frameSize = sizeBytes.buffer.asByteData().getUint32(0, Endian.big);

        if (frameSize == 0 || frameSize > 10 * 1024 * 1024) {
          _log('  ⚠ 异常帧大小: $frameSize, 跳过');
          continue;
        }

        final frameData = await ensureBytes(frameSize);
        frameCount++;
        if (frameCount <= 3) {
          _log('  → 帧 #$frameCount: pts=$pts size=$frameSize first=${frameData.sublist(0, frameData.length > 4 ? 4 : frameData.length)}');
        }
        // Send H.264 frame to UI
        _videoFrameController.add(frameData);
      }
    } catch (e) {
      _log('  ✗ 视频流错误: $e');
      if (_state == ScrcpyState.connected) {
        _updateState(ScrcpyState.error);
      }
    } finally {
      reader.dispose();
      await socket.close();
    }
  }

  /// Read video frames from ADB stream, auto-detect device header.
  /// Read raw video stream from localhost:videoPort.
  /// Data format: [device_header_72B] [pts(8) + size(4) + frame(size)] ...
  void _readVideoFramesFromSocket(_SocketReader reader, Socket socket, int? qW, int? qH) async {
    try {
      _log('  → _readVideoFramesFromSocket 启动');
      final buf = BytesBuilder();
      var frameCount = 0;

      Future<Uint8List> ensureBytes(int n) async {
        while (buf.length < n) {
          final chunk = await reader.readRaw(4096).timeout(const Duration(seconds: 10));
          if (chunk.isEmpty) throw Exception('Socket EOF');
          buf.add(chunk);
        }
        final result = Uint8List.fromList(buf.toBytes().sublist(0, n));
        final remaining = buf.toBytes().sublist(n);
        buf.clear();
        buf.add(remaining);
        return result;
      }

      // Read first 100 bytes to detect format
      final probe = await ensureBytes(100);
      _log('  → 前100字节: ${probe.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      _log('  → ASCII: ${String.fromCharCodes(probe.map((b) => b >= 32 && b < 127 ? b : 46))}');

      // Check if first 64 bytes look like a device name (printable ASCII)
      final first64 = probe.sublist(0, 64);
      final printableCount = first64.where((b) => b >= 32 && b < 127).length;
      if (printableCount > 40) {
        // Device header: name(64) + codec_id(4 LE) + width(4 LE)
        _log('  → 检测到 device header!');
        final deviceName = String.fromCharCodes(first64).trimRight();
        final codecId = probe.buffer.asByteData().getUint32(64, Endian.little);
        final width = probe.buffer.asByteData().getUint32(68, Endian.little);
        _log('  → deviceName=$deviceName codec=$codecId width=$width');
        final height = qH ?? _deviceInfo?.videoHeight ?? 1280;
        _deviceInfo = DeviceInfo(deviceName: deviceName, videoWidth: width, videoHeight: height);
        _deviceInfoController.add(_deviceInfo!);
      } else {
        _log('  → 无 device header');
        final w = qW ?? _deviceInfo?.videoWidth ?? 720;
        final h = qH ?? _deviceInfo?.videoHeight ?? 1280;
        _deviceInfo = DeviceInfo(deviceName: 'redroid', videoWidth: w, videoHeight: h);
        _deviceInfoController.add(_deviceInfo!);
      }

      _log('⑨ 开始接收视频帧...');
      while (_state == ScrcpyState.connected) {
        final ptsBytes = await ensureBytes(8);
        final pts = ptsBytes.buffer.asByteData().getInt64(0, Endian.big);
        final sizeBytes = await ensureBytes(4);
        final frameSize = sizeBytes.buffer.asByteData().getUint32(0, Endian.big);

        if (frameSize == 0 || frameSize > 10 * 1024 * 1024) {
          _log('  ⚠ 异常帧: pts=$pts size=$frameSize');
          // Try raw stream: just push bytes as-is
          _videoFrameController.add(Uint8List.fromList([...ptsBytes, ...sizeBytes]));
          frameCount++;
          while (_state == ScrcpyState.connected) {
            final raw = await ensureBytes(4096);
            _videoFrameController.add(raw);
            frameCount++;
            if (frameCount <= 5) _log('  → 裸帧 #$frameCount: ${raw.length}B');
          }
          break;
        }

        final frameData = await ensureBytes(frameSize);
        frameCount++;
        if (frameCount <= 3) {
          _log('  → 帧 #$frameCount: pts=$pts size=$frameSize first=${frameData.sublist(0, frameData.length > 8 ? 8 : frameData.length).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        }
        _videoFrameController.add(frameData);
      }
    } catch (e) {
      _log('  ✗ 视频流错误: $e');
      if (_state == ScrcpyState.connected) _updateState(ScrcpyState.error);
    } finally {
      reader.dispose();
      await socket.close();
    }
  }

  /// Bridge ADB stream (WRTE messages) → raw TCP socket.
  /// Reads WRTE from ADB, extracts payload, writes raw to TCP.
  /// Also ACKs WRTE messages back to the ADB daemon.
  void _bridgeAdbToTcp(
    _SocketReader adbReader, Socket adbSocket,
    int localId, int remoteId,
    Socket tcpSocket,
  ) async {
    try {
      _log('  → _bridgeAdbToTcp 启动');
      var chunkCount = 0;
      while (_state == ScrcpyState.connected) {
        final msg = await _recvAdbMsg(adbReader);
        if (msg.cmd == WRTE_V) {
          // Extract payload from WRTE and write raw to TCP
          tcpSocket.add(msg.payload);
          await tcpSocket.flush();
          // ACK the WRTE
          await _sendAdbMsg(adbSocket, OKAY_V, localId, msg.arg0);
          chunkCount++;
          if (chunkCount <= 3) {
            _log('  → bridge WRTE[$chunkCount]: ${msg.payload.length}B');
          }
        } else if (msg.cmd == CLSE_V) {
          _log('  → bridge: stream closed');
          break;
        } else if (msg.cmd == OKAY_V) {
          // ignore
        }
      }
    } catch (e) {
      _log('  → bridge error: $e');
    } finally {
      try { tcpSocket.close(); } catch (_) {}
    }
  }

  /// Read raw H.264 from ADB stream (send_frame_meta=false, send_device_meta=false, send_codec_meta=true).
  /// Codec header: codec_id(1) + width(4 BE) + height(4 BE) = 9 bytes, then raw H.264 NAL units.
  void _readRawH264FromAdb(_SocketReader reader, Socket socket, int? qW, int? qH) async {
    try {
      _log('  → _readRawH264FromAdb 启动');
      final buf = BytesBuilder();

      Future<Uint8List> ensureBytes(int n) async {
        while (buf.length < n) {
          final msg = await _recvAdbMsg(reader);
          if (msg.cmd == WRTE_V) {
            await _sendAdbMsg(socket, OKAY_V, msg.arg1, msg.arg0);
            buf.add(msg.payload);
          } else if (msg.cmd == CLSE_V) {
            throw Exception('Connection closed');
          }
        }
        final all = buf.toBytes();
        final result = Uint8List.fromList(all.sublist(0, n));
        buf.clear();
        if (all.length > n) buf.add(all.sublist(n));
        return result;
      }

      // Read codec header: codec_id(1) + width(4 BE) + height(4 BE)
      final codecHeader = await ensureBytes(9);
      final codecId = codecHeader[0];
      final width = codecHeader.buffer.asByteData().getUint32(1, Endian.big);
      final height = codecHeader.buffer.asByteData().getUint32(5, Endian.big);
      _log('  → codec=$codecId size=${width}x$height');
      _deviceInfo = DeviceInfo(deviceName: 'redroid', videoWidth: width, videoHeight: height);
      _deviceInfoController.add(_deviceInfo!);

      var chunkCount = 0;
      while (_state == ScrcpyState.connected) {
        final msg = await _recvAdbMsg(reader);
        if (msg.cmd == WRTE_V) {
          await _sendAdbMsg(socket, OKAY_V, msg.arg1, msg.arg0);
          _videoFrameController.add(msg.payload);
          chunkCount++;
          if (chunkCount <= 5) {
            final first4 = msg.payload.length >= 4
                ? msg.payload.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')
                : '(短)';
            _log('  → H.264 chunk #$chunkCount: ${msg.payload.length}B first4=$first4');
          }
        } else if (msg.cmd == CLSE_V) {
          _log('  → stream closed');
          break;
        }
      }
    } catch (e) {
      _log('  ✗ 视频流错误: $e');
      if (_state == ScrcpyState.connected) _updateState(ScrcpyState.error);
    } finally {
      reader.dispose();
      await socket.close();
    }
  }

  /// Read video frames from ADB stream.
  /// With send_device_meta=true + send_frame_meta=true:
  ///   First WRTE: 64B device name
  ///   Then: PTS(8 BE) + size(4 BE) + H.264 data, accumulated across WRTEs
  /// Read video frames from ADB stream with PTS+size parsing.
  /// send_device_meta=true: first 64B = device name, skip it.
  /// send_frame_meta=true: PTS(8 BE) + size(4 BE) + H.264 data per frame.
  void _readVideoFramesFromAdb(_SocketReader reader, Socket socket, int? qW, int? qH) async {
    try {
      _log('  → _readVideoFramesFromAdb 启动');
      final buf = BytesBuilder();
      var frameCount = 0;

      Future<Uint8List> ensureBytes(int n) async {
        while (buf.length < n) {
          final msg = await _recvAdbMsg(reader);
          if (msg.cmd == WRTE_V) {
            await _sendAdbMsg(socket, OKAY_V, msg.arg1, msg.arg0);
            buf.add(msg.payload);
          } else if (msg.cmd == CLSE_V) {
            throw Exception('Connection closed');
          }
        }
        final all = buf.toBytes();
        final result = Uint8List.fromList(all.sublist(0, n));
        buf.clear();
        if (all.length > n) buf.add(all.sublist(n));
        return result;
      }

      // v4.0 stream: [device_name(64B)] [codec_id(4B)] [SESSION/Frames...]
      // Smart device name detection: check first byte
      final probe = await ensureBytes(1);
      final firstByte = probe[0];
      _log('  → probe: 0x${firstByte.toRadixString(16).padLeft(2, '0')}');

      if (firstByte >= 32 && firstByte < 127) {
        // Printable ASCII → device name header, skip remaining 63B
        final nameBytes = await ensureBytes(63);
        final name = String.fromCharCodes([firstByte, ...nameBytes.where((b) => b >= 32 && b < 127)]).trimRight();
        _log('  → device: $name');
        final w = qW ?? _deviceInfo?.videoWidth ?? 720;
        final h = qH ?? _deviceInfo?.videoHeight ?? 1280;
        _deviceInfo = DeviceInfo(deviceName: name.isEmpty ? 'redroid' : name, videoWidth: w, videoHeight: h);

        // v4.0: read codec header (4B codec ID) if send_stream_meta=true
        final codecProbe = await ensureBytes(4);
        final codecId = codecProbe.buffer.asByteData().getUint32(0, Endian.big);
        _log('  → codec ID: $codecId');
      } else {
        // Not printable → no device name
        _log('  → 无 device header');
        final prev = buf.toBytes();
        buf.clear();
        buf.add(probe);
        buf.add(prev);
        final w = qW ?? _deviceInfo?.videoWidth ?? 720;
        final h = qH ?? _deviceInfo?.videoHeight ?? 1280;
        _deviceInfo = DeviceInfo(deviceName: 'redroid', videoWidth: w, videoHeight: h);
      }
      _deviceInfoController.add(_deviceInfo!);

      // Read frames — v4.0 format:
      // SESSION packet: flags(4B) + width(4B) + height(4B) = 12B, bit31 of flags set
      // Frame: PTS+Flags(8B BE) + Size(4B BE) + Data, PTS bits 63-61 are flags
      _log('⑧ 开始接收视频帧...');
      while (_state == ScrcpyState.connected) {
        // Peek first 4 bytes to distinguish SESSION vs frame
        final first4 = await ensureBytes(4);
        final first4Val = first4.buffer.asByteData().getUint32(0, Endian.big);

        if (first4Val & 0x80000000 != 0) {
          // SESSION packet: this 4B is flags, read width(4B) + height(4B)
          final whBytes = await ensureBytes(8);
          final whBd = whBytes.buffer.asByteData();
          final w = whBd.getUint32(0, Endian.big);
          final h = whBd.getUint32(4, Endian.big);
          if (w > 0 && h > 0 && w < 10000 && h < 10000) {
            _log('  → SESSION: ${w}x$h');
            _resolutionChangeController.add((width: w.toInt(), height: h.toInt()));
            if (_deviceInfo != null &&
                (_deviceInfo!.videoWidth != w.toInt() || _deviceInfo!.videoHeight != h.toInt())) {
              _deviceInfo = DeviceInfo(
                deviceName: _deviceInfo!.deviceName,
                videoWidth: w.toInt(),
                videoHeight: h.toInt(),
              );
              _deviceInfoController.add(_deviceInfo!);
            }
          }
          continue;
        }

        // Frame: first 4B is high 4 bytes of PTS+Flags, read remaining 4B of PTS
        final ptsLow = await ensureBytes(4);
        final ptsRaw = (first4Val.toInt() << 32) | ptsLow.buffer.asByteData().getUint32(0, Endian.big);
        // Mask off bits 63-61 (SESSION/CONFIG/KEY_FRAME flags)
        final pts = ptsRaw & 0x1FFFFFFFFFFFFFFF;

        final sizeBytes = await ensureBytes(4);
        final frameSize = sizeBytes.buffer.asByteData().getUint32(0, Endian.big);

        if (frameSize == 0 || frameSize > 10 * 1024 * 1024) {
          _log('  ⚠ 异常帧: pts=$pts size=$frameSize');
          continue;
        }

        final frameData = await ensureBytes(frameSize);
        frameCount++;
        if (frameCount <= 10) {
          final first8 = frameData.length >= 8
              ? frameData.sublist(0, 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')
              : frameData.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
          _log('  → 帧 #$frameCount: pts=$pts size=$frameSize first8=$first8');
        }

        _videoFrameController.add(frameData);
      }
    } catch (e) {
      _log('  ✗ 视频流错误: $e');
      if (_state == ScrcpyState.connected) _updateState(ScrcpyState.error);
    } finally {
      reader.dispose();
      await socket.close();
    }
  }

  /// Read server output (WRTE messages) to drain the ADB shell connection.
  /// This keeps the server alive by preventing buffer overflow.
  void _readServerOutput(_SocketReader reader, Socket socket) async {
    try {
      while (_state != ScrcpyState.disconnected) {
        final msg = await _recvAdbMsg(reader);
        if (msg.cmd == WRTE_V) {
          // Server output (e.g. log messages)
          final text = utf8.decode(msg.payload, allowMalformed: true).trim();
          if (text.isNotEmpty) {
            _log('  [server] $text');
          }
          // ACK the WRTE: arg0=our_local_id, arg1=server_remote_id
          await _sendAdbMsg(socket, OKAY_V, msg.arg1, msg.arg0);
        } else if (msg.cmd == CLSE_V) {
          _log('  [server] 收到 CLSE');
          // Don't reply - just let connection die naturally
          break;
        }
      }
    } catch (e) {
      if (e is TimeoutException) {
        // Server silence is normal after startup - don't set error state
        _log('  [server] 超时 (正常); state=${_state}');
      } else {
        _log('  [server] 连接断开: $e');
        // Don't set error state - video connection is separate
      }
    }
  }

  /// Connect via Python bridge (TCP direct, no ADB protocol)
  /// Bridge runs on Kali: adb forward + TCP proxy
  Future<void> connectBridge({required String bridgeHost, int bridgePort = 19877}) async {
    if (_state == ScrcpyState.connected || _state == ScrcpyState.connecting) return;
    _updateState(ScrcpyState.connecting);

    try {
      _log('① 连接 bridge $bridgeHost:$bridgePort ...');
      final socket = await Socket.connect(bridgeHost, bridgePort, timeout: const Duration(seconds: 10));
      _log('  ✓ TCP 连接成功');

      final reader = _SocketReader(socket);

      // Set device info (hardcoded for now, bridge doesn't send it)
      const width = 720;
      const height = 1280;
      _deviceInfo = DeviceInfo(deviceName: 'redroid', videoWidth: width, videoHeight: height);
      _deviceInfoController.add(_deviceInfo!);
      _log('  → 分辨率: ${width}x$height');

      _updateState(ScrcpyState.connected);
      _log('② 开始接收视频帧...');

      // Read frames from raw socket
      // _readVideoFramesFromSocket(reader, socket);  // removed: old duplicate
    } catch (e) {
      String msg;
      if (e is PlatformException) {
        msg = '错误: ${e.message}\n${e.details ?? ''}';
      } else {
        msg = '错误: $e';
      }
      _log('✗ $msg');
      _updateState(ScrcpyState.error);
      disconnect();
    }
  }

  int? _lastSpsWidth;
  int? _lastSpsHeight;

  /// Scan a video frame for SPS NAL units and update resolution if changed.
  void _checkSpsResolution(Uint8List frameData, int frameCount) {
    for (final nal in SpsParser.findNalUnits(frameData)) {
      if (nal.type == 7) { // SPS
        final res = SpsParser.parseSps(nal.data);
        if (res != null) {
          if (_lastSpsWidth != res.width || _lastSpsHeight != res.height) {
            _lastSpsWidth = res.width;
            _lastSpsHeight = res.height;
            _log('  → SPS 分辨率变化: ${res.width}x${res.height}');
            _resolutionChangeController.add((width: res.width, height: res.height));
            // Update device info if resolution actually changed
            if (_deviceInfo != null &&
                (_deviceInfo!.videoWidth != res.width || _deviceInfo!.videoHeight != res.height)) {
              _deviceInfo = DeviceInfo(
                deviceName: _deviceInfo!.deviceName,
                videoWidth: res.width,
                videoHeight: res.height,
              );
              _deviceInfoController.add(_deviceInfo!);
              _log('  → DeviceInfo 已更新: ${res.width}x${res.height}');
            }
          }
        }
      }
    }
  }

  void disconnect() {
    _controlSub?.cancel();
    _controlSub = null;
    _controlSocket = null;
    _controlRemoteId = null;
    _deviceInfo = null;
    _updateState(ScrcpyState.disconnected);
  }
  /// Drain OKAY/CLSE responses from control connection
  void _drainControlResponses(_SocketReader reader, Socket socket) async {
    try {
      while (_state == ScrcpyState.connected) {
        final msg = await _recvAdbMsg(reader);
        if (msg.cmd == CLSE_V) break;
        if (msg.cmd == WRTE_V) {
          // ACK the WRTE so server can send more
          await _sendAdbMsg(socket, OKAY_V, msg.arg1, msg.arg0);
        }
        // OKAY — just drain
      }
    } catch (_) {}
  }

  /// Send binary control message via control WRITE socket (no reader bound)
  Future<void> _sendControlMsg(int type, Uint8List payload) async {
    final cs = _controlSocket;
    if (cs == null) {
      _log('  ⚠ _sendControlMsg: socket=null');
      return;
    }
    try {
      final msg = BytesBuilder();
      msg.add([type]);
      msg.add(payload);
      await _sendAdbMsg(cs, WRTE_V, 3, _controlRemoteId ?? 0, msg.toBytes());
    } catch (e) {
      _log('  ⚠ _sendControlMsg error: $e');
    }
  }

  int _lastTouchX = 0;
  int _lastTouchY = 0;

  Future<void> sendTouchEvent(dynamic e) async {
    if (_host == null) return;
    try {
      final action = e.action as int;
      final x = e.positionX as int;
      final y = e.positionY as int;
      final w = e.screenWidth as int;
      final h = e.screenHeight as int;

      // Binary control protocol
      if (_controlSocket != null && _controlRemoteId != null) {
        final buf = ByteData(31);
        buf.setUint8(0, action);
        buf.setInt64(1, 0, Endian.big);
        buf.setInt32(9, x, Endian.big);
        buf.setInt32(13, y, Endian.big);
        buf.setInt16(17, w, Endian.big);
        buf.setInt16(19, h, Endian.big);
        buf.setUint16(21, action == 1 ? 0 : 0xFFFF, Endian.big);
        buf.setInt32(23, 0, Endian.big);
        buf.setInt32(27, 0, Endian.big);
        await _sendControlMsg(2, buf.buffer.asUint8List());
        return;
      }

      // Fallback: shell commands
      if (action == 0) {
        _lastTouchX = x;
        _lastTouchY = y;
      } else if (action == 1) {
        if (x == _lastTouchX && y == _lastTouchY) {
          AdbClient.execShell(_host!, _port, 'input tap $x $y').timeout(const Duration(seconds: 3));
        } else {
          AdbClient.execShell(_host!, _port, 'input swipe $_lastTouchX $_lastTouchY $x $y 200').timeout(const Duration(seconds: 3));
        }
      }
    } catch (_) {}
  }

  Future<void> sendScrollEvent(dynamic e) async {
    if (_host == null) return;
    try {
      final x = e.positionX as int;
      final y = e.positionY as int;
      final w = e.screenWidth as int;
      final h = e.screenHeight as int;
      final sx = e.scrollX as int;
      final sy = e.scrollY as int;

      if (_controlSocket != null && _controlRemoteId != null) {
        final buf = ByteData(20);
        buf.setInt32(0, x, Endian.big);
        buf.setInt32(4, y, Endian.big);
        buf.setInt16(8, w, Endian.big);
        buf.setInt16(10, h, Endian.big);
        buf.setInt32(12, sx, Endian.big);
        buf.setInt32(16, sy, Endian.big);
        await _sendControlMsg(3, buf.buffer.asUint8List());
        return;
      }

      // Fallback
      if (sy != 0) {
        final cmd = sy > 0 ? 'input swipe 360 800 360 400 200' : 'input swipe 360 400 360 800 200';
        AdbClient.execShell(_host!, _port, cmd).timeout(const Duration(seconds: 3));
      }
    } catch (_) {}
  }

  Future<void> sendKeyEvent(dynamic e) async {
    if (_host == null) return;
    try {
      final keycode = e.keycode as int;
      final action = e.action as int;

      if (_controlSocket != null && _controlRemoteId != null) {
        final buf = ByteData(13);
        buf.setInt32(0, action, Endian.big);
        buf.setInt32(4, keycode, Endian.big);
        buf.setInt32(8, 0, Endian.big);
        buf.setUint8(12, 0);
        await _sendControlMsg(0, buf.buffer.asUint8List());
        return;
      }

      // Fallback
      AdbClient.execShell(_host!, _port, 'input keyevent $keycode').timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<void> sendBackOrScreenOn() async {
    if (_host == null) return;
    try {
      AdbClient.execShell(_host!, _port, 'input keyevent KEYCODE_WAKEUP; input keyevent KEYCODE_MENU').timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  @override
  void dispose() {
    disconnect();
    _stateController.close(); _deviceInfoController.close();
    _videoFrameController.close(); _errorController.close();
    _resolutionChangeController.close();
    super.dispose();
  }
}
