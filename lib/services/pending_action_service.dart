import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PendingExternalAction {
  none,
  profileImagePicker,
  contactPicker,
}

class PendingActionService {
  static const String _keyPendingAction = 'pending_external_action';
  static const String _keySavedRouteIndex = 'pending_saved_route_index';
  static const String _keyTempFormName = 'pending_temp_form_name';
  static const String _keyTempFormEmail = 'pending_temp_form_email';

  static Future<void> savePendingAction({
    required PendingExternalAction action,
    required int routeIndex,
    String? tempName,
    String? tempEmail,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPendingAction, action.name);
    await prefs.setInt(_keySavedRouteIndex, routeIndex);
    if (tempName != null) await prefs.setString(_keyTempFormName, tempName);
    if (tempEmail != null) await prefs.setString(_keyTempFormEmail, tempEmail);
    debugPrint('[SafeRoute] Saved pending action: ${action.name}, routeIndex: $routeIndex');
  }

  static Future<PendingExternalAction> getPendingAction() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(_keyPendingAction);
    if (str == null || str.isEmpty) return PendingExternalAction.none;
    return PendingExternalAction.values.firstWhere(
      (e) => e.name == str,
      orElse: () => PendingExternalAction.none,
    );
  }

  static Future<int?> getSavedRouteIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keySavedRouteIndex);
  }

  static Future<Map<String, String>> getTempFormState() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name': prefs.getString(_keyTempFormName) ?? '',
      'email': prefs.getString(_keyTempFormEmail) ?? '',
    };
  }

  static Future<void> clearPendingAction() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPendingAction);
    await prefs.remove(_keySavedRouteIndex);
    await prefs.remove(_keyTempFormName);
    await prefs.remove(_keyTempFormEmail);
    debugPrint('[SafeRoute] Cleared pending action.');
  }
}
