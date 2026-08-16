import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:get/get.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/pending_action_service.dart';

class ContactController extends GetxController {
  static ContactController instanceOrCreate() {
    if (Get.isRegistered<ContactController>()) {
      return Get.find<ContactController>();
    }
    return Get.put(ContactController());
  }

  var contacts = <String>[].obs;
  var isSmsPermissionGranted = false.obs;

  @override
  void onInit() {
    super.onInit();
    loadContacts();
    refreshSmsPermissionStatus();
    checkPendingPickedContact();
  }

  Future<void> checkPendingPickedContact() async {
    try {
      const channel = MethodChannel('safe_route/sms');
      final Map<dynamic, dynamic>? res = await channel.invokeMethod('getPendingPickedContact');
      if (res?['hasPending'] == true) {
        final phone = res?['phoneNumber']?.toString() ?? '';
        final cleanPhone = phone.replaceAll(RegExp(r'[^\d+]'), '');
        if (cleanPhone.isNotEmpty) {
          await addContact(cleanPhone);
        }
      }
    } catch (e) {
      debugPrint('Error checking pending picked contact: $e');
    }
  }

  Future<void> refreshSmsPermissionStatus() async {
    final smsStatus = await Permission.sms.status;
    final phoneStatus = await Permission.phone.status;
    isSmsPermissionGranted.value = smsStatus.isGranted && phoneStatus.isGranted;
  }

  Future<bool> checkAndRequestSmsPermission({
    bool requestIfNeeded = true,
  }) async {
    final smsStatus = await Permission.sms.status;
    final phoneStatus = await Permission.phone.status;
    final alreadyGranted = smsStatus.isGranted && phoneStatus.isGranted;
    if (alreadyGranted) {
      isSmsPermissionGranted.value = true;
      return true;
    }

    if (!requestIfNeeded) {
      isSmsPermissionGranted.value = false;
      return false;
    }

    final statuses = await [Permission.sms, Permission.phone].request();
    final resolvedSms = statuses[Permission.sms] ?? smsStatus;
    final resolvedPhone = statuses[Permission.phone] ?? phoneStatus;
    final granted = resolvedSms.isGranted && resolvedPhone.isGranted;

    isSmsPermissionGranted.value = granted;

    if (resolvedSms.isPermanentlyDenied || resolvedPhone.isPermanentlyDenied) {
      _showPermanentlyDeniedDialog();
    } else if (!granted) {
      Get.snackbar(
        'Permission Denied',
        'Direct SOS SMS is disabled until SMS and phone permissions are granted.',
      );
    }

    return granted;
  }

  void _showPermanentlyDeniedDialog() {
    Get.defaultDialog(
      title: "Permission Required",
      middleText:
          "SMS permission is permanently denied. Please enable it in App Settings to use the SOS feature to send direct messages.",
      textConfirm: "Open Settings",
      onConfirm: () {
        openAppSettings();
        Get.back();
      },
      textCancel: "Cancel",
    );
  }

  Future<void> loadContacts() async {
    final prefs = await SharedPreferences.getInstance();
    contacts.value = prefs.getStringList('emergency_contacts') ?? [];
  }

  Future<void> addContact(String phoneNumber) async {
    if (contacts.length >= 4) {
      Get.snackbar(
        "Limit Reached",
        "SafeRoute supports up to 4 emergency contacts.",
      );
      return;
    }

    if (phoneNumber.isNotEmpty && !contacts.contains(phoneNumber)) {
      contacts.add(phoneNumber);
      await _saveContacts();
      await _syncContactsToFirestore();
      Get.snackbar("Success", "Contact added successfully");
    }
  }

  Future<void> removeContact(String phoneNumber) async {
    contacts.remove(phoneNumber);
    await _saveContacts();
    await _syncContactsToFirestore();
  }

  Future<String?> pickContactFromPhonebook() async {
    try {
      final status = await Permission.contacts.request();
      if (!status.isGranted) {
        Get.snackbar(
          "Permission Required",
          "Please grant Contacts permission to select contacts from your phonebook.",
          snackPosition: SnackPosition.TOP,
        );
        return null;
      }

      await PendingActionService.savePendingAction(
        action: PendingExternalAction.contactPicker,
        routeIndex: 2,
      );

      const channel = MethodChannel('safe_route/sms');
      final Map<dynamic, dynamic>? res = await channel.invokeMethod('pickContactFromPhonebook');
      await checkPendingPickedContact();
      if (res?['success'] == true) {
        final phone = res?['phoneNumber']?.toString() ?? '';
        final cleanPhone = phone.replaceAll(RegExp(r'[^\d+]'), '');
        if (cleanPhone.isNotEmpty) {
          await addContact(cleanPhone);
          return cleanPhone;
        }
      } else if (res?['errorMessage'] != null && res?['errorMessage'] != 'No contact selected.') {
        Get.snackbar(
          "Phonebook Notice",
          res!['errorMessage'].toString(),
          snackPosition: SnackPosition.TOP,
        );
      }
    } catch (e) {
      Get.snackbar(
        "Phonebook Error",
        "Unable to pick contact from device phonebook.",
        snackPosition: SnackPosition.TOP,
      );
    }
    return null;
  }

  Future<void> updateContact(String oldValue, String newValue) async {
    final index = contacts.indexOf(oldValue);
    if (index == -1 || newValue.isEmpty) return;

    contacts[index] = newValue;
    await _saveContacts();
    await _syncContactsToFirestore();
  }

  Future<void> _saveContacts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('emergency_contacts', contacts);
  }

  Future<void> _syncContactsToFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final data = <String, dynamic>{
      'emergencyContact1': contacts.isNotEmpty ? contacts[0] : '',
      'emergencyContact2': contacts.length > 1 ? contacts[1] : '',
      'emergencyContact3': contacts.length > 2 ? contacts[2] : '',
      'emergencyContact4': contacts.length > 3 ? contacts[3] : '',
    };

    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set(data, SetOptions(merge: true));
  }
}
