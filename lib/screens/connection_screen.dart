import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/adb_client.dart';
import '../services/scrcpy_connection.dart';
import 'screen_viewer.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '5555');
  List<SavedDevice> _savedDevices = [];
  bool _isConnecting = false;
  List<String> _logMessages = [];
  StreamSubscription? _errorSub;
  ServerConfig _serverConfig = ServerConfig();

  @override
  void initState() {
    super.initState();
    _loadSavedDevices();
    _loadServerConfig();
  }

  Future<void> _loadServerConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('server_config');
    if (json != null) {
      setState(() {
        _serverConfig = ServerConfig.fromJson(jsonDecode(json));
      });
    }
  }

  Future<void> _saveServerConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_config', jsonEncode(_serverConfig.toJson()));
  }

  Future<void> _loadSavedDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('saved_devices') ?? '[]';
    final list = jsonDecode(json) as List;
    setState(() {
      _savedDevices = list.map((e) => SavedDevice.fromJson(e)).toList();
    });
  }

  Future<void> _saveDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final json = _savedDevices.map((e) => e.toJson()).toList();
    await prefs.setString('saved_devices', jsonEncode(json));
  }

  Future<void> _connect(String host, int port) async {
    if (_isConnecting) return;

    setState(() {
      _isConnecting = true;
      _logMessages = [];
    });

    _errorSub?.cancel();

    final conn = context.read<ScrcpyConnection>();
    conn.config = _serverConfig;

    late StreamSubscription sub;
    sub = conn.stateStream.listen((state) {
      if (!mounted) return;
      if (state == ScrcpyState.connected) {
        _saveDevice(host, port);
        sub.cancel();
        setState(() { _isConnecting = false; _logMessages = []; });
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ScreenViewer(connection: context.read<ScrcpyConnection>(), host: host, port: port),
          ),
        );
      } else if (state == ScrcpyState.error) {
        sub.cancel();
        setState(() => _isConnecting = false);
      }
    });

    _errorSub = conn.errorStream.listen((msg) {
      if (mounted && _isConnecting) {
        // Only show error messages during connecting phase
        if (msg.contains('失败') || msg.contains('错误') || msg.contains('failed') || msg.contains('error') || msg.contains('✗') || msg.contains('⚠')) {
          setState(() => _logMessages.add(msg));
        }
      }
    });

    await conn.connect(host: host, port: port);
  }

  void _saveDevice(String host, int port) async {
    // Get device name from ADB settings
    String deviceName;
    try {
      deviceName = await AdbClient.execShell(host, port, 'settings get global device_name');
      deviceName = deviceName.trim();
      if (deviceName.isEmpty || deviceName == 'null') {
        deviceName = host;
      }
    } catch (_) {
      deviceName = host;
    }
    final existing = _savedDevices.indexWhere(
      (d) => d.host == host && d.port == port,
    );
    if (existing >= 0) {
      _savedDevices[existing].lastUsed = DateTime.now();
      _savedDevices[existing].label = deviceName;
    } else {
      _savedDevices.add(SavedDevice(
        host: host,
        port: port,
        label: deviceName,
        lastUsed: DateTime.now(),
      ));
    }
    _savedDevices.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    _saveDevices();
  }

  void _deleteDevice(int index) async {
    setState(() => _savedDevices.removeAt(index));
    await _saveDevices();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              Center(
                child: Column(
                  children: [
                    const Icon(Icons.phone_android, size: 64, color: Colors.deepPurple),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Redroid Controller',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          icon: const Icon(Icons.settings, color: Colors.grey),
                          onPressed: _showSettings,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Saved devices
              if (_savedDevices.isNotEmpty) ...[
                const Text('已保存的设备', style: TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 8),
                ...List.generate(_savedDevices.length, (i) {
                  final dev = _savedDevices[i];
                  return Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: _isConnecting ? null : () => _connect(dev.host, dev.port),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            const Text('📱', style: TextStyle(fontSize: 22)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(dev.label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  Text('${dev.host}:${dev.port}', style: const TextStyle(fontSize: 13, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                            if (_isConnecting)
                              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            else
                              IconButton(
                                icon: const Icon(Icons.delete, size: 20, color: Colors.grey),
                                onPressed: () => _deleteDevice(i),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                const Text('手动连接', style: TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 8),
              ],

              // Manual input
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: '设备 IP',
                  hintText: '192.168.x.x 或 IPv6 地址',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.router),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _portController,
                decoration: const InputDecoration(
                  labelText: 'ADB 端口',
                  hintText: '5555',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.numbers),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _isConnecting ? null : () {
                    final host = _hostController.text.trim();
                    final port = int.tryParse(_portController.text.trim()) ?? 5555;
                    if (host.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请输入设备 IP')),
                      );
                      return;
                    }
                    _connect(host, port);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                  ),
                  child: _isConnecting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('连接'),
                ),
              ),

              // Connection log — only show on error
              if (_logMessages.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red[900]?.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red[700]!),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('连接失败', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      ..._logMessages.map((msg) => Text(
                        msg,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.redAccent,
                        ),
                      )),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showSettings() {
    final cfg = _serverConfig;
    final waitController = TextEditingController(text: (cfg.serverWaitMs / 1000).toStringAsFixed(1));
    final maxFpsController = TextEditingController(text: cfg.maxFps.toString());
    final bitRateController = TextEditingController(text: (cfg.videoBitRate / 1000000).toStringAsFixed(1));
    final bufferController = TextEditingController(text: cfg.videoBuffer.toString());
    String selectedCodec = cfg.videoCodec;
    String selectedEncoder = cfg.videoEncoder;

    const codecs = ['h264', 'h265', 'av1'];
    const encoders = [
      'OMX.google.h264.encoder',
      'OMX.google.h265.encoder',
      'c2.android.av1.encoder',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('服务器参数', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(
                controller: waitController,
                decoration: const InputDecoration(
                  labelText: '等待 server 启动 (秒)',
                  hintText: '1.0',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.timer),
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: maxFpsController,
                decoration: const InputDecoration(
                  labelText: '最大帧率 (max_fps)',
                  hintText: '30',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.speed),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bitRateController,
                decoration: const InputDecoration(
                  labelText: '视频码率 (Mbps)',
                  hintText: '4.0',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.high_quality),
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: selectedCodec,
                decoration: const InputDecoration(
                  labelText: '视频编码 (video_codec)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.videocam),
                ),
                items: codecs.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setSheetState(() => selectedCodec = v!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: selectedEncoder,
                decoration: const InputDecoration(
                  labelText: '编码器 (video_encoder)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.memory),
                ),
                items: encoders.map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 13)))).toList(),
                onChanged: (v) => setSheetState(() => selectedEncoder = v!),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bufferController,
                decoration: const InputDecoration(
                  labelText: '视频缓冲 (video_buffer)',
                  hintText: '0',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.storage),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () {
                    cfg.serverWaitMs = ((double.tryParse(waitController.text) ?? 1.0) * 1000).toInt();
                    cfg.maxFps = int.tryParse(maxFpsController.text) ?? 30;
                    cfg.videoBitRate = ((double.tryParse(bitRateController.text) ?? 4.0) * 1000000).toInt();
                    cfg.videoCodec = selectedCodec;
                    cfg.videoEncoder = selectedEncoder;
                    cfg.videoBuffer = int.tryParse(bufferController.text) ?? 0;
                    _saveServerConfig();
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }
}

class SavedDevice {
  String host;
  int port;
  String label;
  DateTime lastUsed;

  SavedDevice({
    required this.host,
    required this.port,
    required this.label,
    required this.lastUsed,
  });

  factory SavedDevice.fromJson(Map<String, dynamic> json) => SavedDevice(
    host: json['host'],
    port: json['port'],
    label: json['label'] ?? json['host'],
    lastUsed: DateTime.parse(json['lastUsed']),
  );

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'label': label,
    'lastUsed': lastUsed.toIso8601String(),
  };
}
