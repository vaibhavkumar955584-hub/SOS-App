import 'package:flutter_test/flutter_test.dart';
import 'package:safe_route/services/location_fallback_service.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  group('LocationResolutionResult Contract Enforcement', () {
    test('Tier 1 result enforces tierFired=1 and isFallback=false', () {
      final pos = Position(
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );

      final res = LocationResolutionResult(
        position: pos,
        statusLabel: 'GPS High-Accuracy',
        tierFired: 1,
        isFallback: false,
      );

      expect(res.position, isNotNull);
      expect(res.tierFired, equals(1));
      expect(res.isFallback, isFalse);
      expect(res.statusLabel, contains('GPS High-Accuracy'));
    });

    test('Tier 4 result enforces tierFired=4 and isFallback=true', () {
      final pos = Position(
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: DateTime.now(),
        accuracy: 50.0,
        altitude: 0.0,
        heading: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
        altitudeAccuracy: 0.0,
        headingAccuracy: 0.0,
      );

      final res = LocationResolutionResult(
        position: pos,
        statusLabel: 'Cached Fix (5 min ago)',
        tierFired: 4,
        isFallback: true,
      );

      expect(res.position, isNotNull);
      expect(res.tierFired, equals(4));
      expect(res.isFallback, isTrue);
      expect(res.formattedPayload, contains('Location: Last Known'));
    });

    test('Tier 5 result enforces position=null, tierFired=5, and isFallback=true', () {
      final res = LocationResolutionResult(
        position: null,
        statusLabel: 'Location Unavailable Flag',
        tierFired: 5,
        isFallback: true,
      );

      expect(res.position, isNull);
      expect(res.tierFired, equals(5));
      expect(res.isFallback, isTrue);
      expect(res.formattedPayload, equals('Location: No location available (GPS/Network Disabled)'));
    });
  });
}
