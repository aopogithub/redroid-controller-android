import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/adb_client.dart';

class FileUploadScreen extends StatefulWidget {
  final String host;
  final int port;

  const FileUploadScreen({super.key, required this.host, this.port = 5555});

  @override
  State<FileUploadScreen> createState() => _FileUploadScreenState();
}

class _FileUploadScreenState extends State<FileUploadScreen> {
  final _pathController = TextEditingController(text: '/data/local/tmp/');
  final _uploadLog = <_UploadEntry>[];
  bool _uploading = false;

  Future<void> _pickAndUpload() async {
    if (_uploading) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final localPath = file.path;
      if (localPath == null) {
        _addLog('错误: 无法获取文件路径', isError: true);
        return;
      }

      final remotePath = '${_pathController.text}${file.name}';
      setState(() => _uploading = true);
      _addLog('正在上传: ${file.name} (${_formatSize(file.size)})', isError: false);
      _addLog('目标路径: $remotePath', isError: false);

      final fileBytes = await File(localPath).readAsBytes();
      await AdbClient.pushFileTo(widget.host, widget.port, fileBytes.toList(), remotePath);

      _addLog('✓ 上传成功', isError: false);
    } catch (e) {
      _addLog('✗ 上传失败: $e', isError: true);
    }

    setState(() => _uploading = false);
  }

  void _addLog(String text, {required bool isError}) {
    setState(() {
      _uploadLog.add(_UploadEntry(text: text, isError: isError, time: DateTime.now()));
    });
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2D2D2D),
        title: const Text('上传文件', style: TextStyle(color: Colors.white, fontSize: 16)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('目标路径', style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _pathController,
              style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 14),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF2D2D2D),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                hintText: '/data/local/tmp/',
                hintStyle: const TextStyle(color: Colors.white38),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _uploading ? null : _pickAndUpload,
                icon: _uploading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_file),
                label: Text(_uploading ? '上传中...' : '选择文件并上传'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('上传日志', style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2D2D2D),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _uploadLog.length,
                  itemBuilder: (ctx, i) {
                    final entry = _uploadLog[i];
                    return Text(
                      entry.text,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: entry.isError ? Colors.redAccent : Colors.greenAccent,
                        height: 1.5,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }
}

class _UploadEntry {
  final String text;
  final bool isError;
  final DateTime time;
  _UploadEntry({required this.text, required this.isError, required this.time});
}
