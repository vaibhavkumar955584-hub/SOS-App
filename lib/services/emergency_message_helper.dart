import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../controllers/rescue_invite_controller.dart';

/// Helper utility to construct rich, standardized, human-readable SOS SMS alerts.
class EmergencyMessageHelper {
  static const MethodChannel _smsChannel = MethodChannel('safe_route/sms');

  static const List<String> _monthNames = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// Resolves the victim's name from Firestore or FirebaseAuth.
  static Future<String?> resolveVictimName({String? uid}) async {
    final effectiveUid = uid ?? FirebaseAuth.instance.currentUser?.uid;
    if (effectiveUid == null || effectiveUid.isEmpty) {
      return null;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(effectiveUid)
          .get();
      final name = doc.data()?['name']?.toString().trim();
      if (name != null && name.isNotEmpty) {
        return name;
      }
    } catch (e) {
      debugPrint('[EmergencyMessageHelper] Error reading victim name from Firestore: $e');
    }

    final displayName = FirebaseAuth.instance.currentUser?.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }

    return null;
  }

  /// Reads current battery percentage (0-100) from native Android BatteryManager.
  static Future<int?> getBatteryLevel() async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      final level = await _smsChannel.invokeMethod<int>('getBatteryLevel');
      if (level != null && level >= 0 && level <= 100) {
        return level;
      }
    } catch (e) {
      debugPrint('[EmergencyMessageHelper] Error reading battery level: $e');
    }
    return null;
  }

  /// Formats date and time into a clear readable string (e.g., "18 Aug 2026, 12:30 PM").
  static String formatTimestamp(DateTime timestamp) {
    try {
      final day = timestamp.day.toString().padLeft(2, '0');
      final month = _monthNames[timestamp.month - 1];
      final year = timestamp.year;
      final hour12 = timestamp.hour == 0
          ? 12
          : (timestamp.hour > 12 ? timestamp.hour - 12 : timestamp.hour);
      final minute = timestamp.minute.toString().padLeft(2, '0');
      final suffix = timestamp.hour >= 12 ? 'PM' : 'AM';

      return '$day $month $year, ${hour12.toString().padLeft(2, '0')}:$minute $suffix';
    } catch (_) {
      return timestamp.toIso8601String();
    }
  }

  /// Builds a complete, professionally formatted SOS SMS message.
  static Future<String> buildSosMessage({
    String? victimName,
    String? uid,
    int? batteryLevel,
    String? lat,
    String? lng,
    String? locationLabel,
    String? sessionId,
    String? customTrackingUrl,
    DateTime? timestamp,
  }) async {
    final effectiveUid = uid ?? FirebaseAuth.instance.currentUser?.uid;
    final resolvedName = victimName ?? await resolveVictimName(uid: effectiveUid);
    final resolvedBattery = batteryLevel ?? await getBatteryLevel();
    final effectiveTimestamp = timestamp ?? DateTime.now();
    final timeStr = formatTimestamp(effectiveTimestamp);

    // Resolve rescue tracking link
    String? trackingUrl = customTrackingUrl;
    if (trackingUrl == null || trackingUrl.isEmpty) {
      final targetSessionId = sessionId ?? effectiveUid;
      if (targetSessionId != null && targetSessionId.isNotEmpty) {
        try {
          final uri = await RescueInviteController.instance
              .createActiveRescueInviteUri(sessionId: targetSessionId);
          trackingUrl = uri?.toString();
        } catch (e) {
          debugPrint('[EmergencyMessageHelper] Failed to create rescue invite: $e');
        }

        if (trackingUrl == null || trackingUrl.isEmpty) {
          trackingUrl = 'https://saferoute-55bb6.web.app/track?uid=$targetSessionId';
        }
      }
    }

    final buffer = StringBuffer();

    // 1. Header
    buffer.writeln('🚨 EMERGENCY SOS ALERT! 🚨');
    buffer.writeln();

    // 2. Victim Need for Help
    if (resolvedName != null && resolvedName.isNotEmpty) {
      buffer.writeln('$resolvedName is in danger and needs immediate help!');
    } else {
      buffer.writeln('I am in danger and need immediate help!');
    }
    buffer.writeln();

    // 3. Battery & Timestamp
    if (resolvedBattery != null) {
      if (resolvedBattery <= 15) {
        buffer.writeln('🔋 Battery: $resolvedBattery% (⚠️ Low Battery)');
      } else {
        buffer.writeln('🔋 Battery: $resolvedBattery%');
      }
    }
    buffer.writeln('🕒 Time: $timeStr');
    buffer.writeln();

    // 4. Location Section
    final hasCoords = lat != null && lng != null && lat.isNotEmpty && lng.isNotEmpty;
    if (hasCoords) {
      if (locationLabel != null && locationLabel.isNotEmpty) {
        buffer.writeln('📍 Location ($locationLabel):');
      } else {
        buffer.writeln('📍 Location (Google Maps):');
      }
      buffer.writeln('https://maps.google.com/?q=$lat,$lng');
    } else if (locationLabel != null && locationLabel.isNotEmpty) {
      buffer.writeln('📍 Location:');
      buffer.writeln(locationLabel);
    }

    // 5. Live Tracking / Rescue Hyperlink
    if (trackingUrl != null && trackingUrl.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('🆘 Live Track & Join Rescue:');
      buffer.writeln(trackingUrl);
    }

    return buffer.toString().trim();
  }
}
