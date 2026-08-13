import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';

import '../screens/join_rescue_invite_screen.dart';
import 'sos_listener_controller.dart';

class RescueInviteController extends GetxController {
  static const inviteLifetime = Duration(minutes: 30);
  static RescueInviteController get instance => Get.find<RescueInviteController>();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final AppLinks _appLinks = AppLinks();

  StreamSubscription<Uri>? _uriSubscription;
  final Rxn<RescueInvitePayload> pendingInvite = Rxn<RescueInvitePayload>();
  final RxBool joinedViaInvite = false.obs;
  String? _presentedInviteKey;

  @override
  void onInit() {
    super.onInit();
    _bootstrapLinks();
  }

  @override
  void onClose() {
    _uriSubscription?.cancel();
    super.onClose();
  }

  Future<Uri?> createActiveRescueInviteUri({String? sessionId}) async {
    final currentUser = _auth.currentUser;
    final resolvedSessionId = sessionId ??
        SosListenerController.instance.activeSosUid.value ??
        (currentUser != null ? currentUser.uid : null);
    if (resolvedSessionId == null || currentUser == null) {
      return null;
    }

    final token = _generateInviteToken();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expiresAtMs = nowMs + inviteLifetime.inMilliseconds;
    final inviterName = await _resolveCurrentUserName();

    await _firestore.collection('active_sos').doc(resolvedSessionId).update({
      'inviteTokens.$token': {
        'token': token,
        'role': 'helper',
        'createdAtMs': nowMs,
        'expiresAtMs': expiresAtMs,
        'invitedByUid': currentUser.uid,
        'invitedByName': inviterName,
        'status': 'active',
      },
    });

    return Uri(
      scheme: 'saferoute',
      host: 'sos',
      path: '/join-rescue',
      queryParameters: {
        'sessionId': resolvedSessionId,
        'token': token,
        'role': 'helper',
        'expiresAt': expiresAtMs.toString(),
      },
    );
  }

  Future<void> shareActiveRescueInvite({String? sessionId}) async {
    final uri = await createActiveRescueInviteUri(sessionId: sessionId);
    if (uri == null) {
      Get.snackbar(
        'No Active Rescue',
        'You can share a rescue link only while participating in an active SOS session.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }

    await Share.share(
      'Join this active SafeRoute rescue session:\n${uri.toString()}',
      subject: 'SafeRoute Rescue Invite',
    );
  }

  Future<RescueInvitePreview> loadInvitePreview(
    RescueInvitePayload payload,
  ) async {
    final doc = await _firestore
        .collection('active_sos')
        .doc(payload.sessionId)
        .get();
    final data = doc.data();
    if (!doc.exists || data == null || data['active'] != true) {
      return RescueInvitePreview.invalid('This rescue link is no longer valid.');
    }

    final inviteTokens =
        Map<String, dynamic>.from(data['inviteTokens'] as Map? ?? {});
    final tokenData = Map<String, dynamic>.from(
      inviteTokens[payload.token] as Map? ?? {},
    );
    if (tokenData.isEmpty) {
      return RescueInvitePreview.invalid('This rescue link is no longer valid.');
    }

    final expiresAtMs = tokenData['expiresAtMs'] as int?;
    if (expiresAtMs != null &&
        DateTime.now().millisecondsSinceEpoch > expiresAtMs) {
      return RescueInvitePreview.invalid('This rescue link has expired.');
    }

    final currentUser = _auth.currentUser;
    final responders = List<String>.from(
      (data['responders'] as List<dynamic>? ?? []).map((e) => e.toString()),
    );
    if (currentUser != null && responders.contains(currentUser.uid)) {
      return RescueInvitePreview.invalid(
        'You are already part of this rescue session.',
      );
    }

    if (responders.length >= SosListenerController.maxResponders) {
      return RescueInvitePreview.invalid(
        'This rescue session already has the maximum helpers.',
      );
    }

    final victim = _extractVictimLocation(data);
    if (victim == null) {
      return RescueInvitePreview.invalid(
        'The rescue session is missing victim location data.',
      );
    }

    return RescueInvitePreview(
      isValid: true,
      sessionId: payload.sessionId,
      token: payload.token,
      victimLocation: victim,
      inviterName: tokenData['invitedByName']?.toString(),
      invitedByUid: tokenData['invitedByUid']?.toString(),
      responderCount: responders.length,
      expiresAtMs: expiresAtMs,
    );
  }

  Future<RescueJoinResult> joinInvite(RescueInvitePayload payload) async {
    final preview = await loadInvitePreview(payload);
    if (!preview.isValid || preview.victimLocation == null) {
      return RescueJoinResult(
        success: false,
        errorMessage: preview.errorMessage ?? 'This rescue link is invalid.',
      );
    }

    final user = _auth.currentUser;
    if (user == null) {
      pendingInvite.value = payload;
      return const RescueJoinResult(
        success: false,
        errorMessage: 'Please log in first to join this rescue session.',
      );
    }

    final result = await SosListenerController.instance.joinRescueSession(
      sosUid: payload.sessionId,
      target: preview.victimLocation!,
      joinSource: 'invite_link',
      inviteToken: payload.token,
      invitedByUid: preview.invitedByUid,
      invitedByName: preview.inviterName,
    );

    if (result.success) {
      joinedViaInvite.value = true;
      pendingInvite.value = null;
      _presentedInviteKey = null;
    }

    return result;
  }

  void processPendingInviteAfterAuth() {
    if (_auth.currentUser == null) {
      return;
    }
    final invite = pendingInvite.value;
    if (invite == null) {
      return;
    }
    _routeInvite(invite);
  }

  void clearInviteJoinBadge() {
    joinedViaInvite.value = false;
  }

  Future<void> _bootstrapLinks() async {
    try {
      final initialLink = await _appLinks.getInitialLink();
      if (initialLink != null) {
        _handleUri(initialLink);
      }
    } catch (e) {
      debugPrint('Failed to read initial rescue invite link: $e');
    }

    _uriSubscription = _appLinks.uriLinkStream.listen(
      _handleUri,
      onError: (Object error) {
        debugPrint('Rescue invite link stream error: $error');
      },
    );
  }

  void _handleUri(Uri uri) {
    final payload = _parseInvite(uri);
    if (payload == null) {
      return;
    }

    pendingInvite.value = payload;
    _routeInvite(payload);
  }

  void _routeInvite(RescueInvitePayload payload) {
    final user = _auth.currentUser;
    if (user == null) {
      Get.snackbar(
        'Login Required',
        'Please log in to join this rescue session.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }

    final inviteKey = '${payload.sessionId}:${payload.token}';
    if (_presentedInviteKey == inviteKey) {
      return;
    }
    _presentedInviteKey = inviteKey;

    Get.to(
      () => JoinRescueInviteScreen(invite: payload),
      transition: Transition.rightToLeftWithFade,
      duration: const Duration(milliseconds: 250),
    );
  }

  RescueInvitePayload? _parseInvite(Uri uri) {
    final isSafeRouteInvite =
        uri.scheme == 'saferoute' &&
        uri.host == 'sos' &&
        uri.path.contains('join-rescue');
    if (!isSafeRouteInvite) {
      return null;
    }

    final sessionId = uri.queryParameters['sessionId'];
    final token = uri.queryParameters['token'];
    final role = uri.queryParameters['role'];
    final expiresAtRaw = uri.queryParameters['expiresAt'];
    if (sessionId == null ||
        token == null ||
        role != 'helper' ||
        sessionId.isEmpty ||
        token.isEmpty) {
      return null;
    }

    return RescueInvitePayload(
      sessionId: sessionId,
      token: token,
      role: 'helper',
      expiresAtMs: int.tryParse(expiresAtRaw ?? ''),
    );
  }

  Future<String> _resolveCurrentUserName() async {
    final user = _auth.currentUser;
    if (user == null) {
      return 'SafeRoute Helper';
    }

    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      final data = doc.data();
      final name = data?['name']?.toString().trim();
      if (name != null && name.isNotEmpty) {
        return name;
      }
    } catch (e) {
      debugPrint('Failed to resolve inviter name: $e');
    }

    final displayName = user.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }
    return 'SafeRoute Helper';
  }

  String _generateInviteToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  LatLng? _extractVictimLocation(Map<String, dynamic> data) {
    final victim = data['victim'];
    if (victim is Map) {
      final normalized = Map<String, dynamic>.from(victim);
      final lat = (normalized['lat'] as num?)?.toDouble();
      final lng = (normalized['lng'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        return LatLng(lat, lng);
      }
    }

    final lat = (data['latitude'] as num?)?.toDouble();
    final lng = (data['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) {
      return null;
    }
    return LatLng(lat, lng);
  }
}

class RescueInvitePayload {
  const RescueInvitePayload({
    required this.sessionId,
    required this.token,
    required this.role,
    this.expiresAtMs,
  });

  final String sessionId;
  final String token;
  final String role;
  final int? expiresAtMs;
}

class RescueInvitePreview {
  const RescueInvitePreview({
    required this.isValid,
    this.errorMessage,
    this.sessionId,
    this.token,
    this.victimLocation,
    this.inviterName,
    this.invitedByUid,
    this.responderCount,
    this.expiresAtMs,
  });

  final bool isValid;
  final String? errorMessage;
  final String? sessionId;
  final String? token;
  final LatLng? victimLocation;
  final String? inviterName;
  final String? invitedByUid;
  final int? responderCount;
  final int? expiresAtMs;

  factory RescueInvitePreview.invalid(String message) {
    return RescueInvitePreview(
      isValid: false,
      errorMessage: message,
    );
  }
}
