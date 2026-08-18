import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:safe_route/services/background_shake_service.dart';

void main() {
  group('Voice SOS helpers', () {
    test('matches emergency phrases reliably', () {
      // English
      expect(matchesEmergencyVoicePhrase('help me please'), isTrue);
      expect(matchesEmergencyVoicePhrase('SAVE ME now'), isTrue);
      expect(matchesEmergencyVoicePhrase('this is an sos'), isTrue);
      expect(matchesEmergencyVoicePhrase('medical emergency'), isTrue);
      expect(matchesEmergencyVoicePhrase('someone help me out'), isTrue);

      // Hinglish
      expect(matchesEmergencyVoicePhrase('mujhe bachao koi'), isTrue);
      expect(matchesEmergencyVoicePhrase('bachao bachao'), isTrue);
      expect(matchesEmergencyVoicePhrase('meri madad karo'), isTrue);
      expect(matchesEmergencyVoicePhrase('police bulao jaldi'), isTrue);
      expect(matchesEmergencyVoicePhrase('khatra hai yahan'), isTrue);

      // Hindi (Devanagari)
      expect(matchesEmergencyVoicePhrase('मुझे बचाओ'), isTrue);
      expect(matchesEmergencyVoicePhrase('बचाओ बचाओ'), isTrue);
      expect(matchesEmergencyVoicePhrase('मेरी मदद करो'), isTrue);
      expect(matchesEmergencyVoicePhrase('पुलिस बुलाओ'), isTrue);
      expect(matchesEmergencyVoicePhrase('हेल्प मी'), isTrue);

      // Non-emergency phrases
      expect(matchesEmergencyVoicePhrase('just checking directions'), isFalse);
      expect(matchesEmergencyVoicePhrase('where is the nearest cafe'), isFalse);
      expect(matchesEmergencyVoicePhrase(''), isFalse);
    });

    test('builds m4a recording file name with session id', () {
      final fileName = buildSosRecordingFileName(
        'session123',
        4,
        DateTime(2026, 4, 25, 1, 45, 30),
      );

      expect(
        fileName,
        startsWith('sos_audio_session123_part_4_20260425_014530'),
      );
      expect(fileName, endsWith('.m4a'));
    });
  });

  group('EmergencyShakeDetector', () {
    test('ignores normal walking and jogging movements (no false alarm)', () {
      final detector = EmergencyShakeDetector();
      final baseTime = DateTime(2026, 8, 18, 12, 0, 0);

      // Simulating fast walking / gentle jogging (magnitude ~12-16 m/s²)
      for (int i = 0; i < 10; i++) {
        final sign = i.isEven ? 1.0 : -1.0;
        final triggered = detector.register(
          UserAccelerometerEvent(0, sign * 14.0, 0, DateTime.now()),
          baseTime.add(Duration(milliseconds: i * 250)),
        );
        expect(triggered, isFalse, reason: 'Walking/jogging should never trigger SOS');
      }
    });

    test('ignores single sudden impact like placing phone on table', () {
      final detector = EmergencyShakeDetector();
      final baseTime = DateTime(2026, 8, 18, 12, 0, 0);

      // Single sharp impact (magnitude 28 m/s²) without alternating oscillations
      final triggered = detector.register(
        UserAccelerometerEvent(0, 0, 28.0, DateTime.now()),
        baseTime,
      );
      expect(triggered, isFalse, reason: 'Single impact must not trigger SOS');
    });

    test('detects violent phone snatching tug / struggle', () {
      final detector = EmergencyShakeDetector();
      final baseTime = DateTime(2026, 8, 18, 12, 0, 0);

      // Violent snatch tug: sharp acceleration spike >= 36 m/s² with rapid struggle reversal
      detector.register(
        UserAccelerometerEvent(38.0, 0, 0, DateTime.now()),
        baseTime,
      );
      final triggered = detector.register(
        UserAccelerometerEvent(-37.0, 0, 0, DateTime.now()),
        baseTime.add(const Duration(milliseconds: 200)),
      );
      expect(triggered, isTrue, reason: 'Violent phone snatching should trigger SOS');
    });

    test('detects high-force intentional emergency shake', () {
      final detector = EmergencyShakeDetector();
      final baseTime = DateTime(2026, 8, 18, 12, 0, 0);

      // 4 strong alternating oscillations (magnitude >= 27 m/s²)
      expect(
        detector.register(
          UserAccelerometerEvent(0, 28.0, 0, DateTime.now()),
          baseTime,
        ),
        isFalse,
      );
      expect(
        detector.register(
          UserAccelerometerEvent(0, -28.0, 0, DateTime.now()),
          baseTime.add(const Duration(milliseconds: 200)),
        ),
        isFalse,
      );
      expect(
        detector.register(
          UserAccelerometerEvent(0, 28.0, 0, DateTime.now()),
          baseTime.add(const Duration(milliseconds: 400)),
        ),
        isFalse,
      );
      expect(
        detector.register(
          UserAccelerometerEvent(0, -28.0, 0, DateTime.now()),
          baseTime.add(const Duration(milliseconds: 600)),
        ),
        isTrue,
        reason: '4 strong alternating shakes must trigger SOS',
      );
    });
  });
}
