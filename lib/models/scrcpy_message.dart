import 'dart:typed_data';

/// Scrcpy message types (client → server)
class ScrcpyMessageType {
  static const int injectKeycode = 0;
  static const int injectText = 1;
  static const int injectTouchEvent = 2;
  static const int injectScrollEvent = 3;
  static const int backOrScreenOn = 4;
  static const int expandNotificationPanel = 5;
  static const int expandSettingsPanel = 6;
  static const int collapsePanels = 7;
  static const int getClipboard = 8;
  static const int setClipboard = 9;
  static const int ackClipboard = 10;
  static const int startRecording = 11;
  static const int rotateDevice = 12;
}

/// Touch event action types
class TouchAction {
  static const int down = 0;
  static const int up = 1;
  static const int move = 2;
}

/// Control message for touch injection
class TouchEvent {
  final int action; // TouchAction.down, up, move
  final int pointerId;
  final int positionX;
  final int positionY;
  final int screenWidth;
  final int screenHeight;
  final int pressure; // 0-65535
  final int buttons; // button state bitmask

  TouchEvent({
    required this.action,
    required this.pointerId,
    required this.positionX,
    required this.positionY,
    required this.screenWidth,
    required this.screenHeight,
    this.pressure = 65535,
    this.buttons = 0,
  });

  /// Encode touch event to bytes for scrcpy protocol
  Uint8List encode() {
    final buffer = BytesBuilder();
    
    // Message type (1 byte)
    buffer.addByte(ScrcpyMessageType.injectTouchEvent);
    
    // Action (1 byte)
    buffer.addByte(action);
    
    // Pointer ID (8 bytes, big-endian)
    final pointerIdBytes = ByteData(8);
    pointerIdBytes.setUint64(0, pointerId, Endian.big);
    buffer.add(pointerIdBytes.buffer.asUint8List());
    
    // Position X (4 bytes, big-endian)
    final posXBytes = ByteData(4);
    posXBytes.setUint32(0, positionX, Endian.big);
    buffer.add(posXBytes.buffer.asUint8List());
    
    // Position Y (4 bytes, big-endian)
    final posYBytes = ByteData(4);
    posYBytes.setUint32(0, positionY, Endian.big);
    buffer.add(posYBytes.buffer.asUint8List());
    
    // Screen width (4 bytes, big-endian)
    final widthBytes = ByteData(4);
    widthBytes.setUint32(0, screenWidth, Endian.big);
    buffer.add(widthBytes.buffer.asUint8List());
    
    // Screen height (4 bytes, big-endian)
    final heightBytes = ByteData(4);
    heightBytes.setUint32(0, screenHeight, Endian.big);
    buffer.add(heightBytes.buffer.asUint8List());
    
    // Pressure (2 bytes, big-endian)
    final pressureBytes = ByteData(2);
    pressureBytes.setUint16(0, pressure, Endian.big);
    buffer.add(pressureBytes.buffer.asUint8List());
    
    // Buttons (4 bytes, big-endian)
    final buttonsBytes = ByteData(4);
    buttonsBytes.setUint32(0, buttons, Endian.big);
    buffer.add(buttonsBytes.buffer.asUint8List());
    
    return buffer.toBytes();
  }
}

/// Scroll event for scrcpy
class ScrollEvent {
  final int positionX;
  final int positionY;
  final int screenWidth;
  final int screenHeight;
  final int scrollX;
  final int scrollY;
  final int buttons;

  ScrollEvent({
    required this.positionX,
    required this.positionY,
    required this.screenWidth,
    required this.screenHeight,
    this.scrollX = 0,
    this.scrollY = 0,
    this.buttons = 0,
  });

  Uint8List encode() {
    final buffer = BytesBuilder();
    
    // Message type
    buffer.addByte(ScrcpyMessageType.injectScrollEvent);
    
    // Position X (4 bytes, big-endian)
    final posXBytes = ByteData(4);
    posXBytes.setUint32(0, positionX, Endian.big);
    buffer.add(posXBytes.buffer.asUint8List());
    
    // Position Y (4 bytes, big-endian)
    final posYBytes = ByteData(4);
    posYBytes.setUint32(0, positionY, Endian.big);
    buffer.add(posYBytes.buffer.asUint8List());
    
    // Screen width (4 bytes, big-endian)
    final widthBytes = ByteData(4);
    widthBytes.setUint32(0, screenWidth, Endian.big);
    buffer.add(widthBytes.buffer.asUint8List());
    
    // Screen height (4 bytes, big-endian)
    final heightBytes = ByteData(4);
    heightBytes.setUint32(0, screenHeight, Endian.big);
    buffer.add(heightBytes.buffer.asUint8List());
    
    // Scroll X (4 bytes, big-endian)
    final scrollXBytes = ByteData(4);
    scrollXBytes.setInt32(0, scrollX, Endian.big);
    buffer.add(scrollXBytes.buffer.asUint8List());
    
    // Scroll Y (4 bytes, big-endian)
    final scrollYBytes = ByteData(4);
    scrollYBytes.setInt32(0, scrollY, Endian.big);
    buffer.add(scrollYBytes.buffer.asUint8List());
    
    // Buttons (4 bytes, big-endian)
    final buttonsBytes = ByteData(4);
    buttonsBytes.setUint32(0, buttons, Endian.big);
    buffer.add(buttonsBytes.buffer.asUint8List());
    
    return buffer.toBytes();
  }
}

/// Keycode event for scrcpy
class ScrcpyKeyEvent {
  final int action; // AndroidKeyEvent.ACTION_DOWN or ACTION_UP
  final int keycode; // Android keycode

  ScrcpyKeyEvent({
    required this.action,
    required this.keycode,
  });

  Uint8List encode() {
    final buffer = BytesBuilder();
    
    // Message type
    buffer.addByte(ScrcpyMessageType.injectKeycode);
    
    // Action (1 byte)
    buffer.addByte(action);
    
    // Keycode (4 bytes, big-endian)
    final keycodeBytes = ByteData(4);
    keycodeBytes.setUint32(0, keycode, Endian.big);
    buffer.add(keycodeBytes.buffer.asUint8List());
    
    // Repeat (4 bytes, big-endian) - 0 for no repeat
    final repeatBytes = ByteData(4);
    repeatBytes.setUint32(0, 0, Endian.big);
    buffer.add(repeatBytes.buffer.asUint8List());
    
    // Meta state (4 bytes, big-endian)
    final metaBytes = ByteData(4);
    metaBytes.setUint32(0, 0, Endian.big);
    buffer.add(metaBytes.buffer.asUint8List());
    
    return buffer.toBytes();
  }
}

/// Android key event action
class AndroidKeyEvent {
  static const int actionDown = 0;
  static const int actionUp = 1;
}

/// Common Android keycodes
class AndroidKeycode {
  static const int home = 3;
  static const int back = 4;
  static const int enter = 66;
  static const int del = 67;
  static const int tab = 61;
  static const int escape = 111;
  static const int dpadUp = 19;
  static const int dpadDown = 20;
  static const int dpadLeft = 21;
  static const int dpadRight = 22;
  static const int volumeUp = 24;
  static const int volumeDown = 25;
  static const int power = 26;
  static const int appSwitch = 187;
}
