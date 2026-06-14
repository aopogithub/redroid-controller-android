import 'dart:async';
import 'package:flutter/services.dart';

class H264Decoder {
  static const _channel = MethodChannel('com.redroidcontroller/h264');

  int? _textureId;
  bool _initialized = false;

  /// Whether the decoder is ready.
  bool get isInitialized => _initialized;

  /// The Flutter texture ID to use with [Texture] widget.
  int? get textureId => _textureId;

  /// Initialize the H264 decoder with the given resolution.
  /// Returns the texture ID for rendering.
  Future<int> initialize(int width, int height) async {
    if (_initialized && _textureId != null) return _textureId!;

    final result = await _channel.invokeMethod<int>('initialize', {
      'width': width,
      'height': height,
    });

    _textureId = result;
    _initialized = true;
    return _textureId!;
  }

  /// Feed raw H264 data to the decoder.
  /// Returns map: {rendered, codec, csdSet, fc, spsW, spsH}
  Future<Map<String, dynamic>> decode(List<int> h264Data, {int width = 720, int height = 1280}) async {
    if (!_initialized) return {'rendered': 0, 'codec': false, 'csdSet': false, 'fc': 0, 'spsW': 0, 'spsH': 0};
    final result = await _channel.invokeMethod('decode', {'data': h264Data, 'width': width, 'height': height});
    return Map<String, dynamic>.from(result as Map);
  }

  /// Get native H264 log buffer
  Future<String> getLog() async {
    if (!_initialized) return '';
    final result = await _channel.invokeMethod('getLog');
    return result as String? ?? '';
  }

  /// Update SurfaceTexture size (e.g. when SPS resolution is detected)
  Future<void> updateSize(int width, int height) async {
    if (!_initialized) return;
    await _channel.invokeMethod('updateSize', {'width': width, 'height': height});
  }

  /// Release native resources.
  Future<void> dispose() async {
    if (!_initialized) return;
    await _channel.invokeMethod('release');
    _textureId = null;
    _initialized = false;
  }
}
