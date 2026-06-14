import 'package:flutter_test/flutter_test.dart';
import '../lib/models/scrcpy_message.dart';

void main() {
  group('TouchEvent', () {
    test('should encode touch down event', () {
      final event = TouchEvent(
        action: TouchAction.down,
        pointerId: 0,
        positionX: 100,
        positionY: 200,
        screenWidth: 1080,
        screenHeight: 1920,
      );
      
      final encoded = event.encode();
      expect(encoded.length, 32); // 1 + 1 + 8 + 4 + 4 + 4 + 4 + 2 + 4 = 32
      expect(encoded[0], ScrcpyMessageType.injectTouchEvent);
      expect(encoded[1], TouchAction.down);
    });

    test('should encode touch up event', () {
      final event = TouchEvent(
        action: TouchAction.up,
        pointerId: 0,
        positionX: 150,
        positionY: 250,
        screenWidth: 1080,
        screenHeight: 1920,
      );
      
      final encoded = event.encode();
      expect(encoded[0], ScrcpyMessageType.injectTouchEvent);
      expect(encoded[1], TouchAction.up);
    });

    test('should encode touch move event', () {
      final event = TouchEvent(
        action: TouchAction.move,
        pointerId: 0,
        positionX: 300,
        positionY: 400,
        screenWidth: 1080,
        screenHeight: 1920,
      );
      
      final encoded = event.encode();
      expect(encoded[0], ScrcpyMessageType.injectTouchEvent);
      expect(encoded[1], TouchAction.move);
    });

    test('should encode correct position', () {
      final event = TouchEvent(
        action: TouchAction.down,
        pointerId: 0,
        positionX: 540,
        positionY: 960,
        screenWidth: 1080,
        screenHeight: 1920,
      );
      
      final encoded = event.encode();
      // Check position X (bytes 10-13, big-endian uint32)
      final posX = (encoded[10] << 24) | (encoded[11] << 16) | (encoded[12] << 8) | encoded[13];
      expect(posX, 540);
      
      // Check position Y (bytes 14-17, big-endian uint32)
      final posY = (encoded[14] << 24) | (encoded[15] << 16) | (encoded[16] << 8) | encoded[17];
      expect(posY, 960);
    });
  });

  group('ScrcpyKeyEvent', () {
    test('should encode key down event', () {
      final event = ScrcpyKeyEvent(
        action: AndroidKeyEvent.actionDown,
        keycode: AndroidKeycode.home,
      );
      
      final encoded = event.encode();
      expect(encoded.length, 14); // 1 + 1 + 4 + 4 + 4 = 14
      expect(encoded[0], ScrcpyMessageType.injectKeycode);
      expect(encoded[1], AndroidKeyEvent.actionDown);
      
      final keycode = (encoded[2] << 24) | (encoded[3] << 16) | (encoded[4] << 8) | encoded[5];
      expect(keycode, AndroidKeycode.home);
    });

    test('should encode key up event', () {
      final event = ScrcpyKeyEvent(
        action: AndroidKeyEvent.actionUp,
        keycode: AndroidKeycode.back,
      );
      
      final encoded = event.encode();
      expect(encoded[0], ScrcpyMessageType.injectKeycode);
      expect(encoded[1], AndroidKeyEvent.actionUp);
      
      final keycode = (encoded[2] << 24) | (encoded[3] << 16) | (encoded[4] << 8) | encoded[5];
      expect(keycode, AndroidKeycode.back);
    });

    test('should encode volume up key', () {
      final event = ScrcpyKeyEvent(
        action: AndroidKeyEvent.actionDown,
        keycode: AndroidKeycode.volumeUp,
      );
      
      final encoded = event.encode();
      final keycode = (encoded[2] << 24) | (encoded[3] << 16) | (encoded[4] << 8) | encoded[5];
      expect(keycode, AndroidKeycode.volumeUp);
    });
  });

  group('ScrollEvent', () {
    test('should encode scroll event', () {
      final event = ScrollEvent(
        positionX: 540,
        positionY: 960,
        screenWidth: 1080,
        screenHeight: 1920,
        scrollX: 0,
        scrollY: 1,
      );
      
      final encoded = event.encode();
      expect(encoded.length, 29); // 1 + 4 + 4 + 4 + 4 + 4 + 4 + 4 = 30
      expect(encoded[0], ScrcpyMessageType.injectScrollEvent);
      
      final posX = (encoded[1] << 24) | (encoded[2] << 16) | (encoded[3] << 8) | encoded[4];
      expect(posX, 540);
    });
  });

  group('ScrcpyMessageType', () {
    test('message types should have correct values', () {
      expect(ScrcpyMessageType.injectKeycode, 0);
      expect(ScrcpyMessageType.injectText, 1);
      expect(ScrcpyMessageType.injectTouchEvent, 2);
      expect(ScrcpyMessageType.injectScrollEvent, 3);
      expect(ScrcpyMessageType.backOrScreenOn, 4);
    });
  });

  group('AndroidKeycode', () {
    test('keycodes should have correct values', () {
      expect(AndroidKeycode.home, 3);
      expect(AndroidKeycode.back, 4);
      expect(AndroidKeycode.enter, 66);
      expect(AndroidKeycode.del, 67);
      expect(AndroidKeycode.volumeUp, 24);
      expect(AndroidKeycode.volumeDown, 25);
      expect(AndroidKeycode.power, 26);
    });
  });
}
