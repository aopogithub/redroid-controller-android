import 'dart:io';

/// ADB helper service for managing scrcpy server on Redroid
class AdbHelper {
  static const String defaultAdbHost = '192.168.101.188';
  static const int defaultAdbPort = 5555;

  /// Get the scrcpy server jar path
  static Future<String> getServerJarPath() async {
    // Use a temp path; the server jar should be pre-deployed on the device
    return '/data/local/tmp/scrcpy-server.jar';
  }

  /// Build adb command for connecting to remote device
  static String connectAdbCommand({String? host, int? port}) {
    final h = host ?? defaultAdbHost;
    final p = port ?? defaultAdbPort;
    return 'adb connect $h:$p';
  }

  /// Build adb push command to push scrcpy server to device
  static Future<String> pushServerCommand({String? host, int? port}) async {
    final jarPath = await getServerJarPath();
    final h = host ?? defaultAdbHost;
    final p = port ?? defaultAdbPort;
    return 'adb -s $h:$p push $jarPath /data/local/tmp/scrcpy-server.jar';
  }

  /// Build adb shell command to start scrcpy server
  static String startServerCommand({String? host, int? port}) {
    final h = host ?? defaultAdbHost;
    final p = port ?? defaultAdbPort;
    return 'adb -s $h:$p shell '
        'CLASSPATH=/data/local/tmp/scrcpy-server.jar '
        'app_process / com.genymobile.scrcpy.Server 2.0';
  }

  /// Execute an adb command and return output
  static Future<String> executeCommand(String command) async {
    try {
      final result = await Process.run('sh', ['-c', command]);
      if (result.exitCode != 0) {
        return 'Error (exit code ${result.exitCode}): ${result.stderr}';
      }
      return result.stdout.toString();
    } catch (e) {
      return 'Failed to execute command: $e';
    }
  }

  /// Connect to a device via adb
  static Future<String> connectDevice({String? host, int? port}) async {
    final command = connectAdbCommand(host: host, port: port);
    return executeCommand(command);
  }

  /// Push scrcpy server to device
  static Future<String> pushServer({String? host, int? port}) async {
    final command = await pushServerCommand(host: host, port: port);
    return executeCommand(command);
  }

  /// Start scrcpy server on device
  static Future<String> startServer({String? host, int? port}) async {
    final command = startServerCommand(host: host, port: port);
    return executeCommand(command);
  }

  /// Get device screen size
  static Future<String> getScreenSize({String? host, int? port}) async {
    final h = host ?? defaultAdbHost;
    final p = port ?? defaultAdbPort;
    final command = 'adb -s $h:$p shell wm size';
    return executeCommand(command);
  }

  /// Get device properties
  static Future<String> getDeviceProperties({String? host, int? port}) async {
    final h = host ?? defaultAdbHost;
    final p = port ?? defaultAdbPort;
    final command = 'adb -s $h:$p shell getprop';
    return executeCommand(command);
  }

  /// List connected devices
  static Future<String> listDevices() async {
    return executeCommand('adb devices');
  }

  /// Check if device is connected
  static Future<bool> isDeviceConnected({String? host, int? port}) async {
    final output = await listDevices();
    final h = host ?? defaultAdbHost;
    final p = port ?? defaultAdbPort;
    return output.contains('$h:$p');
  }

  /// Disconnect from device
  static Future<String> disconnectDevice({String? host, int? port}) async {
    final h = host ?? defaultAdbHost;
    final p = port ?? defaultAdbPort;
    return executeCommand('adb disconnect $h:$p');
  }

  /// Generate a setup script for scrcpy server
  static Future<String> generateSetupScript({
    String? host,
    int? port,
    String? serverVersion,
  }) async {
    final h = host ?? defaultAdbHost;
    final p = port ?? defaultAdbPort;
    final version = serverVersion ?? '2.0';

    final script = '''
#!/bin/bash
# RedroidController - Scrcpy Server Setup Script
# Target: Redroid at $h:$p

set -e

echo "Connecting to device at $h:$p..."
adb connect $h:$p

echo "Waiting for device to be ready..."
adb -s $h:$p wait-for-device

echo "Pushing scrcpy server v$version..."
adb -s $h:$p push /data/local/tmp/scrcpy-server.jar /data/local/tmp/scrcpy-server.jar

echo "Starting scrcpy server..."
adb -s $h:$p shell "CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server $version &"

echo "Server started! You can now connect from RedroidController."
''';

    return script;
  }
}
