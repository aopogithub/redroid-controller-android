import 'dart:async';
import 'package:flutter/material.dart';
import '../services/adb_client.dart';

class ShellScreen extends StatefulWidget {
  final String host;
  final int port;

  const ShellScreen({super.key, required this.host, this.port = 5555});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _outputLines = <_ShellLine>[];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _addLine('ADB Shell 已连接', isError: false);
    _addLine('输入命令后按回车执行', isError: false);
  }

  void _addLine(String text, {required bool isError}) {
    _outputLines.add(_ShellLine(text: text, isError: isError, time: DateTime.now()));
    if (_outputLines.length > 500) {
      _outputLines.removeAt(0);
    }
  }

  Future<void> _execute(String command) async {
    if (command.trim().isEmpty || _running) return;

    setState(() {
      _running = true;
      _addLine('\$ ${command.trim()}', isError: false);
    });

    try {
      final result = await AdbClient.execShell(widget.host, widget.port, command.trim());
      if (result.isNotEmpty) {
        for (final line in result.split('\n')) {
          _addLine(line, isError: false);
        }
      } else {
        _addLine('(无输出)', isError: false);
      }
    } catch (e) {
      _addLine('错误: $e', isError: true);
    }

    setState(() => _running = false);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2D2D2D),
        title: const Text('ADB Shell', style: TextStyle(color: Colors.white, fontSize: 16)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () => setState(() => _outputLines.clear()),
            tooltip: '清空',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _outputLines.length,
                itemBuilder: (ctx, i) {
                  final line = _outputLines[i];
                  return SelectableText(
                    line.text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: line.isError ? Colors.redAccent : Colors.greenAccent,
                      height: 1.4,
                    ),
                  );
                },
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: const Color(0xFF2D2D2D),
            child: Row(
              children: [
                const Text('\$ ', style: TextStyle(color: Colors.green, fontFamily: 'monospace', fontSize: 14)),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: '输入命令...',
                      hintStyle: TextStyle(color: Colors.white38),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                    onSubmitted: (v) {
                      _execute(v);
                      _controller.clear();
                    },
                    enabled: !_running,
                  ),
                ),
                if (_running)
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.green))
                else
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.green),
                    onPressed: () {
                      _execute(_controller.text);
                      _controller.clear();
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class _ShellLine {
  final String text;
  final bool isError;
  final DateTime time;
  _ShellLine({required this.text, required this.isError, required this.time});
}
