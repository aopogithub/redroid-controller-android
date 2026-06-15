import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/scrcpy_connection.dart';
import '../models/scrcpy_message.dart' as models;
import '../services/h264_decoder.dart';
import 'shell_screen.dart';
import 'file_upload_screen.dart';

class ScreenViewer extends StatefulWidget {
  final ScrcpyConnection connection;
  final String host;
  final int port;

  const ScreenViewer({super.key, required this.connection, required this.host, this.port = 5555});

  @override
  State<ScreenViewer> createState() => _ScreenViewerState();
}

class _ScreenViewerState extends State<ScreenViewer> {
  final H264Decoder _decoder = H264Decoder();
  Size _screenSize = Size.zero;
  bool _isInitialized = false;
  int? _textureId;
  Offset? _pinchStart;
  DateTime? _touchStartTime;
  Offset? _touchStartPos;
  Offset? _lastTouchPos;
  String _statusMsg = '';
  String _diagMsg = '';
  String _connLog = '';
  String _nativeLog = '';
  int _frameCount = 0;
  int _renderedCount = 0;
  int _touchWidth = 0;
  int _touchHeight = 0;
  bool _reconnecting = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final deviceInfo = widget.connection.deviceInfo;
      final width = deviceInfo?.videoWidth ?? 720;
      final height = deviceInfo?.videoHeight ?? 1280;
      _screenSize = Size(width.toDouble(), height.toDouble());

      _textureId = await _decoder.initialize(width, height);
      setState(() { _isInitialized = true; });

      // Feed frames to native decoder
      widget.connection.videoFrameStream.listen((frame) async {
        try {
          final res = await _decoder.decode(frame, width: _screenSize.width.toInt(), height: _screenSize.height.toInt());
          final rendered = res['rendered'] as int? ?? 0;
          final decW = res['decW'] as int? ?? 0;
          final decH = res['decH'] as int? ?? 0;
          _frameCount++;
          _renderedCount += rendered;
          _diagMsg = '$_frameCount/$_renderedCount ${decW}x$decH';
          setState(() {});
        } catch (_) {}
      });

      // Connection logs
      widget.connection.errorStream.listen((msg) {
        if (msg.contains('control') || msg.contains('ctrl') || msg.contains('touch') || msg.contains('⚠')) {
          setState(() { _connLog = msg; });
        }
      });

      // Resolution change (from SPS detection)
      widget.connection.resolutionChangeStream.listen((res) {
        _screenSize = Size(res.width.toDouble(), res.height.toDouble());
        _decoder.updateSize(res.width, res.height);
        setState(() {});
      });

      // Native log polling
      Future.doWhile(() async {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return false;
        try {
          final log = await _decoder.getLog();
          if (log.isNotEmpty) setState(() { _nativeLog = log; });
        } catch (_) {}
        return mounted;
      });

      // Auto-reconnect on disconnect
      widget.connection.stateStream.listen((state) {
        if (state == ScrcpyState.disconnected || state == ScrcpyState.error) {
          setState(() { _reconnecting = true; });
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted) {
              widget.connection.connect(host: widget.host, port: widget.port);
            }
          });
        } else if (state == ScrcpyState.connected) {
          setState(() { _reconnecting = false; });
        }
      });
    } catch (e) {
      setState(() { _statusMsg = '初始化失败: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Text(
              '📱 ${widget.connection.deviceInfo?.deviceName ?? 'Redroid'}',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            actions: [
              IconButton(icon: const Icon(Icons.more_vert, color: Colors.white), onPressed: _showTools),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: _isInitialized && _textureId != null
                    ? FittedBox(
                        fit: BoxFit.contain,
                        child: Listener(
                          onPointerDown: (d) { _lastTouchPos = d.localPosition; _handleTouch(action: models.TouchAction.down, position: d.localPosition); },
                          onPointerMove: (d) { _lastTouchPos = d.localPosition; _handleTouch(action: 2, position: d.localPosition); },
                          onPointerUp: (d) { _handleTouch(action: models.TouchAction.up, position: d.localPosition); },
                          child: SizedBox(width: _screenSize.width, height: _screenSize.height, child: Texture(textureId: _textureId!)),
                        ),
                      )
                    : Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(color: Colors.white),
                            const SizedBox(height: 16),
                            Text(_statusMsg, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                          ],
                        ),
                      ),
              ),
              if (_isInitialized)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  color: Colors.black87,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('帧=$_frameCount 渲染=$_renderedCount ${_diagMsg.isNotEmpty ? _diagMsg : ''}', style: const TextStyle(color: Colors.white54, fontSize: 10)),
                    ],
                  ),
                ),
            ],
          ),
        ),

        // Reconnect overlay
        if (_reconnecting)
          Container(
            color: Colors.black54,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text('连接断开，正在重连...', style: TextStyle(color: Colors.white70, fontSize: 12, decoration: TextDecoration.none)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _handleTouch({required int action, required Offset position}) {
    final tw = _touchWidth > 0 ? _touchWidth : _screenSize.width.toInt();
    final th = _touchHeight > 0 ? _touchHeight : _screenSize.height.toInt();
    final deviceX = position.dx.toInt().clamp(0, tw - 1);
    final deviceY = position.dy.toInt().clamp(0, th - 1);
    widget.connection.sendTouchEvent(models.TouchEvent(action: action, pointerId: 0, positionX: deviceX, positionY: deviceY, screenWidth: tw, screenHeight: th));
  }

  void _showTools() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.terminal, color: Colors.green), title: const Text('ADB Shell'), onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => ShellScreen(host: widget.host, port: widget.port)));
            }),
            ListTile(leading: const Icon(Icons.upload_file, color: Colors.blue), title: const Text('上传文件'), onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => FileUploadScreen(host: widget.host, port: widget.port)));
            }),
            const Divider(),
            ListTile(leading: const Icon(Icons.arrow_back), title: const Text('返回'), onTap: () {
              widget.connection.sendKeyEvent(models.ScrcpyKeyEvent(action: models.AndroidKeyEvent.actionDown, keycode: models.AndroidKeycode.back));
              widget.connection.sendKeyEvent(models.ScrcpyKeyEvent(action: models.AndroidKeyEvent.actionUp, keycode: models.AndroidKeycode.back));
              Navigator.pop(ctx);
            }),
            ListTile(leading: const Icon(Icons.power_settings_new, color: Colors.red), title: const Text('唤醒屏幕'), onTap: () { widget.connection.sendBackOrScreenOn(); Navigator.pop(ctx); }),
            ListTile(leading: const Icon(Icons.info_outline), title: const Text('设备信息'), subtitle: Text('${_screenSize.width.toInt()}x${_screenSize.height.toInt()}')),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _decoder.dispose();
    widget.connection.disconnect();
    super.dispose();
  }
}
