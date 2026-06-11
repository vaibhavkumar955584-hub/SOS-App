import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../services/location_service.dart';
import '../screens/map_screen.dart';

class SosListenerController extends GetxController {
  static const int _sosFreshnessWindowMs = 15 * 60 * 1000;
  static const int maxResponders = 6;
  static SosListenerController get instance => Get.find<SosListenerController>();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  StreamSubscription? _sosSubscription;
  final Set<String> _processedSos = {};
  
  // Expose an active target for MapScreen to automatically draw a route towards
  var activeSosTarget = Rx<LatLng?>(null);
  final RxnString activeSosUid = RxnString();
  final RxString activeDestinationName = 'SOS Destination'.obs;
  final isInRescueMode = false.obs;

  @override
  void onInit() {
    super.onInit();
    _startListening();
  }

  @override
  void onClose() {
    _sosSubscription?.cancel();
    super.onClose();
  }

  void _startListening() {
    _sosSubscription = _firestore
        .collection('active_sos')
        .where('active', isEqualTo: true)
        .snapshots()
        .listen((snapshot) {
      for (var change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
          _handleIncomingSos(change.doc);
        } else if (change.type == DocumentChangeType.removed) {
          _handleRemovedSos(change.doc.id);
        }
      }
    });
  }

  Future<void> _handleIncomingSos(DocumentSnapshot doc) async {
    final data = doc.data() as Map<String, dynamic>?; 
    if (data == null) return;

    final uid = data['uid'] as String?;
    final lat = (data['latitude'] as num?)?.toDouble();
    final lng = (data['longitude'] as num?)?.toDouble();
    final startedAtMs = _extractSosTimestampMs(data);
    
    // Ignore invalid data or our own SOS broadcasts
    if (uid == null || lat == null || lng == null) return;
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId != null && uid == currentUserId) return;

    if (startedAtMs != null) {
      final ageMs = DateTime.now().millisecondsSinceEpoch - startedAtMs;
      if (ageMs > _sosFreshnessWindowMs) {
        return;
      }
    }
    
    final responders = data['responders'] as List<dynamic>? ?? [];
    if (responders.length >= 3 && currentUserId != null && !responders.contains(currentUserId)) {
       return; // Cap reached, ignore SOS
    }
    
    // If we have already notified the user about this specific SOS, skip it
    if (_processedSos.contains(uid)) return;

    try {
      Position myPosition = await LocationService.getCurrentPosition();
      
      double distanceInMeters = Geolocator.distanceBetween(
        myPosition.latitude, myPosition.longitude,
        lat, lng
      );

      // If within 5km radius
      if (distanceInMeters <= 5000) {
        _processedSos.add(uid);
        _showIncomingSosAlert(uid, LatLng(lat, lng), distanceInMeters);
      }
    } catch (e) {
      debugPrint("Error processing incoming SOS: \$e");
    }
  }

  void _showIncomingSosAlert(String sosUid, LatLng target, double distance) {
    String formattedDistance = (distance / 1000).toStringAsFixed(1);
    
    Get.defaultDialog(
      title: "🚨 URGENT: SOS NEARBY",
      titleStyle: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 22),
      barrierDismissible: false,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "Someone triggered an SOS $formattedDistance km away from your location!",
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 20),
          const Icon(Icons.warning, color: Colors.redAccent, size: 64),
        ]
      ),
      textConfirm: "Navigate to Help",
      confirmTextColor: Colors.white,
      buttonColor: Colors.redAccent,
      onConfirm: () {
        Get.back(); // close dialog
        _navigateToSos(sosUid, target);
      },
      textCancel: "Ignore",
      cancelTextColor: Colors.grey,
      onCancel: () {
        _dismissIncomingSos(sosUid);
      },
    );
  }

  Future<void> _navigateToSos(String sosUid, LatLng target) async {
    final result = await joinRescueSession(
      sosUid: sosUid,
      target: target,
      joinSource: 'direct_accept',
    );
    if (!result.success && result.errorMessage != null) {
      Get.snackbar(
        'Unable to Join',
        result.errorMessage!,
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
      );
    }
  }

  void _handleRemovedSos(String sosUid) {
    _processedSos.remove(sosUid);
    if (activeSosUid.value == sosUid) {
      clearActiveNavigation();
    }
  }

  void _dismissIncomingSos(String sosUid) {
    _processedSos.add(sosUid);
    if (activeSosUid.value == sosUid) {
      clearActiveNavigation();
    }
  }

  void clearActiveNavigation() {
    activeSosUid.value = null;
    activeSosTarget.value = null;
    activeDestinationName.value = 'SOS Destination';
    isInRescueMode.value = false;
  }

  Future<bool> leaveRescueSession() async {
    final sosUid = activeSosUid.value;
    final currentUser = _auth.currentUser;
    if (sosUid == null || currentUser == null) {
      return false;
    }

    try {
      await _firestore.runTransaction((transaction) async {
        final ref = _firestore.collection('active_sos').doc(sosUid);
        final snapshot = await transaction.get(ref);
        final data = snapshot.data() ?? {};
        final responders = List<String>.from(
          (data['responders'] as List<dynamic>? ?? []).map((e) => e.toString()),
        )..remove(currentUser.uid);

        final updates = <String, dynamic>{
          'responders': FieldValue.arrayRemove([currentUser.uid]),
          'respondersMeta.${currentUser.uid}': FieldValue.delete(),
          'rescueState': responders.isEmpty ? 'waiting_for_responder' : 'active',
          'responderCount': responders.length,
          'lastResponderLeftAt': FieldValue.serverTimestamp(),
        };

        transaction.update(ref, updates);
      });
    } catch (e) {
      debugPrint("Failed to leave rescue session: $e");
      return false;
    }

    clearActiveNavigation();
    return true;
  }

  Future<RescueJoinResult> joinRescueSession({
    required String sosUid,
    required LatLng target,
    required String joinSource,
    String? inviteToken,
    String? invitedByUid,
    String? invitedByName,
  }) async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      return const RescueJoinResult(
        success: false,
        errorMessage: 'Please log in to join this rescue session.',
      );
    }

    try {
      final position = await LocationService.getCurrentPosition();
      final responderName = await _resolveResponderName(currentUser.uid);
      final destinationName = await _resolveDestinationName(target);
      final status = _deriveResponderStatus(position: position, target: target);
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      await _firestore.runTransaction((transaction) async {
        final ref = _firestore.collection('active_sos').doc(sosUid);
        final snapshot = await transaction.get(ref);
        final data = snapshot.data();

        if (data == null || data['active'] != true) {
          throw StateError('This rescue session is no longer active.');
        }

        final responders = List<String>.from(
          (data['responders'] as List<dynamic>? ?? []).map((e) => e.toString()),
        );

        if (!responders.contains(currentUser.uid) &&
            responders.length >= maxResponders) {
          throw StateError('This rescue session already has the maximum helpers.');
        }

        if (inviteToken != null) {
          final inviteTokens =
              Map<String, dynamic>.from(data['inviteTokens'] as Map? ?? {});
          final tokenData = Map<String, dynamic>.from(
            inviteTokens[inviteToken] as Map? ?? {},
          );

          if (tokenData.isEmpty) {
            throw StateError('This rescue link is no longer valid.');
          }

          final expiresAtMs = tokenData['expiresAtMs'] as int?;
          final role = tokenData['role']?.toString();
          if (role != 'helper') {
            throw StateError('This invite link does not allow helper access.');
          }
          if (expiresAtMs != null && nowMs > expiresAtMs) {
            throw StateError('This rescue link has expired.');
          }
        }

        if (!responders.contains(currentUser.uid)) {
          responders.add(currentUser.uid);
        }

        final updates = <String, dynamic>{
          'responders': responders,
          'responderCount': responders.length,
          'rescueState': 'active',
          'updatedAtMs': nowMs,
          'respondersMeta.${currentUser.uid}': {
            'uid': currentUser.uid,
            'name': responderName,
            'latitude': position.latitude,
            'longitude': position.longitude,
            'status': status,
            'joinSource': joinSource,
            'joinedAtMs': nowMs,
            'invitedByUid': invitedByUid,
            'invitedByName': invitedByName,
            'inviteToken': inviteToken,
            'updatedAtMs': nowMs,
            'updatedAt': FieldValue.serverTimestamp(),
          },
        };

        if (inviteToken != null) {
          updates['inviteTokens.$inviteToken.lastJoinedBy'] = currentUser.uid;
          updates['inviteTokens.$inviteToken.lastJoinedAtMs'] = nowMs;
          updates['invitedHelpers.${currentUser.uid}'] = {
            'uid': currentUser.uid,
            'name': responderName,
            'invitedByUid': invitedByUid,
            'invitedByName': invitedByName,
            'inviteToken': inviteToken,
            'joinedAtMs': nowMs,
          };
        }

        transaction.update(ref, updates);
      });

      activeSosUid.value = sosUid;
      activeSosTarget.value = target;
      activeDestinationName.value = destinationName;
      isInRescueMode.value = true;

      if (Get.currentRoute != '/MapScreen') {
        Get.offAll(() => const MapScreen());
      }

      return const RescueJoinResult(success: true);
    } catch (e) {
      debugPrint("Error joining rescue session: $e");
      return RescueJoinResult(
        success: false,
        errorMessage: e is StateError
            ? e.message.toString()
            : 'Unable to join this rescue session right now.',
      );
    }
  }

  Future<void> updateResponderLocation(
    Position position, {
    LatLng? target,
  }) async {
    final sosUid = activeSosUid.value;
    final currentUser = _auth.currentUser;
    if (sosUid == null || currentUser == null) {
      return;
    }

    final responderName = await _resolveResponderName(currentUser.uid);
    final status = _deriveResponderStatus(
      position: position,
      target: target ?? activeSosTarget.value,
    );

    try {
      await _firestore.collection('active_sos').doc(sosUid).update({
        'responders': FieldValue.arrayUnion([currentUser.uid]),
        'responderCount': FieldValue.increment(0),
        'rescueState': 'active',
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
        'respondersMeta.${currentUser.uid}': {
          'uid': currentUser.uid,
          'name': responderName,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'status': status,
          'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      });
    } catch (e) {
      debugPrint("Failed to publish responder location: $e");
    }
  }

  String _deriveResponderStatus({
    required Position position,
    LatLng? target,
  }) {
    if (target == null) {
      return 'Approaching';
    }

    final distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      target.latitude,
      target.longitude,
    );

    if (distance <= 250) {
      return 'Arriving';
    }
    if (distance <= 1000) {
      return 'Nearby';
    }
    return 'Approaching';
  }

  Future<String> _resolveResponderName(String uid) async {
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists) {
        final data = doc.data();
        final name = data?['name']?.toString().trim();
        if (name != null && name.isNotEmpty) {
          return name;
        }
      }
    } catch (e) {
      debugPrint("Failed to resolve responder name: $e");
    }

    final displayName = _auth.currentUser?.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }
    return uid;
  }

  Future<String> _resolveDestinationName(LatLng target) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        target.latitude,
        target.longitude,
      );
      if (placemarks.isEmpty) {
        return _coordinateLabel(target);
      }

      final placemark = placemarks.first;
      final parts = [
        placemark.name,
        placemark.street,
        placemark.subLocality,
        placemark.locality,
      ].whereType<String>().where((part) => part.trim().isNotEmpty).toList();

      if (parts.isEmpty) {
        return _coordinateLabel(target);
      }

      return parts.take(2).join(', ');
    } catch (e) {
      debugPrint("Failed to resolve SOS destination name: $e");
      return _coordinateLabel(target);
    }
  }

  String _coordinateLabel(LatLng target) {
    return '${target.latitude.toStringAsFixed(4)}, ${target.longitude.toStringAsFixed(4)}';
  }

  int? _extractSosTimestampMs(Map<String, dynamic> data) {
    final startedAtMs = data['startedAtMs'];
    if (startedAtMs is int) return startedAtMs;

    final updatedAtMs = data['updatedAtMs'];
    if (updatedAtMs is int) return updatedAtMs;

    final timestamp = data['timestamp'];
    if (timestamp is Timestamp) {
      return timestamp.millisecondsSinceEpoch;
    }
    return null;
  }
}

class RescueJoinResult {
  const RescueJoinResult({
    required this.success,
    this.errorMessage,
  });

  final bool success;
  final String? errorMessage;
}
