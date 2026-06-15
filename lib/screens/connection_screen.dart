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

  @override
  void initState() {
    super.initState();
    _loadSavedDevices();
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
                    const Text(
                      'Redroid Controller',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
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
