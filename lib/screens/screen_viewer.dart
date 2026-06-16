import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  int _touchWidth = 0;
  int _touchHeight = 0;
  bool _reconnecting = false;

  // Perf counters
  int _frameCount = 0;
  int _renderedCount = 0;
  int _skippedCount = 0;
  String _diagMsg = '';
  final ValueNotifier<int> _diagTick = ValueNotifier(0);
  Timer? _diagTimer;
  bool _decoding = false;
  Uint8List? _pendingFrame;

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

      // Feed frames — queue latest, skip intermediates, NO flush
      widget.connection.videoFrameStream.listen((frame) {
        _frameCount++;
        if (_decoding) {
          _pendingFrame = frame;
          return;
        }
        _decodeFrame(frame);
      });

      // Diag ticker — 2 Hz instead of per-frame
      _diagTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted) return;
        _diagMsg = 'in=$_frameCount out=$_renderedCount skip=$_skippedCount '
            '${_screenSize.width.toInt()}x${_screenSize.height.toInt()}';
        _diagTick.value++;
      });

      // Resolution change (from SPS detection)
      widget.connection.resolutionChangeStream.listen((res) {
        _screenSize = Size(res.width.toDouble(), res.height.toDouble());
        _decoder.updateSize(res.width, res.height);
        if (mounted) setState(() {});
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
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    
    // Enter/exit fullscreen based on orientation
    if (isLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }

    return Stack(
      children: [
        Scaffold(
          backgroundColor: Colors.black,
          appBar: isLandscape ? null : AppBar(
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
                  child: ValueListenableBuilder<int>(
                    valueListenable: _diagTick,
                    builder: (_, __, ___) => Text(
                      _diagMsg,
                      style: const TextStyle(color: Colors.white54, fontSize: 10),
                    ),
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

        // Floating tools button in landscape mode
        if (isLandscape && _isInitialized)
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onLongPress: () => Navigator.pop(context),
              child: FloatingActionButton(
                mini: true,
                backgroundColor: Colors.black54,
                onPressed: _showTools,
                child: const Icon(Icons.more_vert, color: Colors.white, size: 20),
              ),
            ),
          ),
      ],
    );
  }

  void _decodeFrame(Uint8List frame) {
    _decoding = true;
    _decoder.decode(frame, width: _screenSize.width.toInt(), height: _screenSize.height.toInt())
        .then((res) {
          final rendered = res['rendered'] as int? ?? 0;
          _renderedCount += rendered;
        })
        .catchError((_) {})
        .whenComplete(() {
          final next = _pendingFrame;
          _pendingFrame = null;
          _decoding = false;
          if (next != null && mounted) {
            _skippedCount++;
            _decodeFrame(next);
          }
        });
  }

  void _handleTouch({required int action, required Offset position}) {
    final tw = _touchWidth > 0 ? _touchWidth : _screenSize.width.toInt();
    final th = _touchHeight > 0 ? _touchHeight : _screenSize.height.toInt();
    final deviceX = position.dx.toInt().clamp(0, tw - 1);
    final deviceY = position.dy.toInt().clamp(0, th - 1);
    widget.connection.sendTouchEvent(models.TouchEvent(action: action, pointerId: 0, positionX: deviceX, positionY: deviceY, screenWidth: tw, screenHeight: th));
  }

  void _showTools() {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final menuItems = _buildMenuItems();

    if (isLandscape) {
      // Right side slide panel in landscape
      showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'tools',
        barrierColor: Colors.black38,
        transitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => const SizedBox.shrink(),
        transitionBuilder: (ctx, anim, _, __) {
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
            child: Align(
              alignment: Alignment.centerRight,
              child: Material(
                color: const Color(0xFF303030),
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), bottomLeft: Radius.circular(12)),
                child: SafeArea(
                  child: SizedBox(
                    width: 220,
                    child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: menuItems),
                  ),
                ),
              ),
            ),
          );
        },
      );
    } else {
      // Bottom sheet in portrait
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: menuItems),
          ),
        ),
      );
    }
  }

  List<Widget> _buildMenuItems() {
    return [
      ListTile(leading: const Icon(Icons.terminal, color: Colors.green), title: const Text('ADB Shell'), onTap: () {
        Navigator.pop(context);
        Navigator.push(context, MaterialPageRoute(builder: (_) => ShellScreen(host: widget.host, port: widget.port)));
      }),
      ListTile(leading: const Icon(Icons.upload_file, color: Colors.blue), title: const Text('上传文件'), onTap: () {
        Navigator.pop(context);
        Navigator.push(context, MaterialPageRoute(builder: (_) => FileUploadScreen(host: widget.host, port: widget.port)));
      }),
      const Divider(),
      ListTile(leading: const Icon(Icons.arrow_back), title: const Text('返回'), onTap: () {
        widget.connection.sendKeyEvent(models.ScrcpyKeyEvent(action: models.AndroidKeyEvent.actionDown, keycode: models.AndroidKeycode.back));
        widget.connection.sendKeyEvent(models.ScrcpyKeyEvent(action: models.AndroidKeyEvent.actionUp, keycode: models.AndroidKeycode.back));
        Navigator.pop(context);
      }),
      ListTile(leading: const Icon(Icons.power_settings_new, color: Colors.red), title: const Text('唤醒屏幕'), onTap: () { widget.connection.sendBackOrScreenOn(); Navigator.pop(context); }),
      ListTile(leading: const Icon(Icons.info_outline), title: const Text('设备信息'), subtitle: Text('${_screenSize.width.toInt()}x${_screenSize.height.toInt()}')),
    ];
  }

  @override
  void dispose() {
    _diagTimer?.cancel();
    _diagTick.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _decoder.dispose();
    widget.connection.disconnect();
    super.dispose();
  }
}
