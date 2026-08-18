import 'package:get/get.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../screens/main_shell_screen.dart';
import '../screens/login_screen.dart';
import 'contact_controller.dart';
import 'rescue_invite_controller.dart';

class AuthController extends GetxController {
  static AuthController get instance => Get.find<AuthController>();

  late Rx<User?> _user;
  final FirebaseAuth auth = FirebaseAuth.instance;
  final FirebaseFirestore firestore = FirebaseFirestore.instance;
  final RxBool isLoading = false.obs;

  @override
  void onReady() {
    super.onReady();
    _user = Rx<User?>(auth.currentUser);
    _user.bindStream(auth.userChanges());
    ever(_user, _initialScreen);
  }

  // Navigate according to auth state changes seamlessly
  void _initialScreen(User? user) {
    if (user == null) {
      Get.offAll(() => const LoginScreen());
    } else {
      _syncUserConstraints(user.uid);
      Get.offAll(() => const MainShellScreen());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (Get.isRegistered<RescueInviteController>()) {
          RescueInviteController.instance.processPendingInviteAfterAuth();
        }
      });
    }
  }

  // Bind emergency contacts into SharedPreferences for native SOS execution
  Future<void> _syncUserConstraints(String uid) async {
    try {
      final doc = await firestore.collection('users').doc(uid).get();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_uid', uid);

      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        final userContacts = <String>[];
        for (var i = 1; i <= 4; i++) {
          final value = data['emergencyContact$i'];
          if (value != null && value.toString().trim().isNotEmpty) {
            userContacts.add(value.toString().trim());
          }
        }

        final name = data['name']?.toString().trim();
        if (name != null && name.isNotEmpty) {
          await prefs.setString('user_name', name);
        }

        // Push into SharedPreferences
        await prefs.setStringList('emergency_contacts', userContacts);

        // Dynamically invoke ContactController if already alive
        if (Get.isRegistered<ContactController>()) {
          Get.find<ContactController>().loadContacts();
        }
      }
    } catch (e) {
      debugPrint("[AuthController] Sync Error: $e");
    }
  }

  String _mapFirebaseAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Invalid email or password. Please check your credentials.';
      case 'email-already-in-use':
        return 'An account already exists for this email address.';
      case 'weak-password':
        return 'Password should be at least 6 characters long.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'user-disabled':
        return 'This user account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again in a few moments.';
      case 'network-request-failed':
        return 'Network connection failed. Please check your internet.';
      default:
        return e.message ?? 'Authentication error occurred.';
    }
  }

  Future<bool> register(
    String name,
    String email,
    String password,
    String phone,
    String ec1,
    String ec2,
  ) async {
    final cleanName = name.trim();
    final cleanEmail = email.trim();
    final cleanPassword = password.trim();
    final cleanPhone = phone.trim();
    final cleanEc1 = ec1.trim();
    final cleanEc2 = ec2.trim();

    if (cleanName.isEmpty || cleanEmail.isEmpty || cleanPassword.isEmpty || cleanPhone.isEmpty || cleanEc1.isEmpty || cleanEc2.isEmpty) {
      Get.snackbar(
        "Missing Fields",
        "Please fill in all required fields.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
      );
      return false;
    }

    if (cleanPassword.length < 6) {
      Get.snackbar(
        "Weak Password",
        "Password must be at least 6 characters.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
      );
      return false;
    }

    try {
      isLoading.value = true;
      final UserCredential cred = await auth.createUserWithEmailAndPassword(
        email: cleanEmail,
        password: cleanPassword,
      );

      if (cred.user != null) {
        await cred.user!.updateDisplayName(cleanName);

        // Immediately hydrate the Firestore blueprint for this UID
        await firestore.collection('users').doc(cred.user!.uid).set({
          'name': cleanName,
          'email': cleanEmail,
          'phone': cleanPhone,
          'emergencyContact1': cleanEc1,
          'emergencyContact2': cleanEc2,
          'emergencyContact3': '',
          'emergencyContact4': '',
          'createdAt': FieldValue.serverTimestamp(),
        });

        await _syncUserConstraints(cred.user!.uid);
      }

      Get.snackbar(
        "Account Created",
        "Welcome to VIGIL, $cleanName!",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.green,
        colorText: Colors.white,
      );
      return true;
    } on FirebaseAuthException catch (e) {
      Get.snackbar(
        "Registration Failed",
        _mapFirebaseAuthError(e),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
        duration: const Duration(seconds: 4),
      );
      return false;
    } catch (e) {
      Get.snackbar(
        "Registration Failed",
        e.toString().replaceFirst(RegExp(r'\[.*\] '), ''),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
      );
      return false;
    } finally {
      isLoading.value = false;
    }
  }

  Future<bool> login(String email, String password) async {
    final cleanEmail = email.trim();
    final cleanPassword = password.trim();

    if (cleanEmail.isEmpty || cleanPassword.isEmpty) {
      Get.snackbar(
        "Missing Credentials",
        "Please enter both email and password.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
      );
      return false;
    }

    try {
      isLoading.value = true;
      final cred = await auth.signInWithEmailAndPassword(
        email: cleanEmail,
        password: cleanPassword,
      );
      if (cred.user != null) {
        await _syncUserConstraints(cred.user!.uid);
      }
      return true;
    } on FirebaseAuthException catch (e) {
      Get.snackbar(
        "Login Failed",
        _mapFirebaseAuthError(e),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
        duration: const Duration(seconds: 4),
      );
      return false;
    } catch (e) {
      Get.snackbar(
        "Login Failed",
        e.toString().replaceFirst(RegExp(r'\[.*\] '), ''),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
      );
      return false;
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> sendPasswordReset(String email) async {
    final cleanEmail = email.trim();
    if (cleanEmail.isEmpty) {
      Get.snackbar(
        "Missing Email",
        "Please enter your email to receive password reset link.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
      );
      return;
    }

    try {
      isLoading.value = true;
      await auth.sendPasswordResetEmail(email: cleanEmail);
      Get.snackbar(
        "Email Sent",
        "Password reset link has been sent to $cleanEmail.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.green,
        colorText: Colors.white,
        duration: const Duration(seconds: 5),
      );
    } on FirebaseAuthException catch (e) {
      Get.snackbar(
        "Reset Failed",
        _mapFirebaseAuthError(e),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
      );
    } catch (e) {
      Get.snackbar(
        "Reset Failed",
        e.toString(),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
      );
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> logout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('emergency_contacts');
      await prefs.remove('user_uid');
      await prefs.remove('user_name');
      await auth.signOut();
    } catch (e) {
      debugPrint("[AuthController] Logout error: $e");
    }
  }
}
