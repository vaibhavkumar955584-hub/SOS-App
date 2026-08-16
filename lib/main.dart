import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:firebase_core/firebase_core.dart';
import 'controllers/heatmap_controller.dart';
import 'controllers/risk_controller.dart';
import 'controllers/sos_controller.dart';
import 'screens/auth_wrapper.dart';
import 'controllers/auth_controller.dart';
import 'controllers/rescue_invite_controller.dart';
import 'controllers/rescue_stats_controller.dart';
import 'controllers/sos_listener_controller.dart';
import 'services/background_shake_service.dart';
import 'firebase_options.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint(
      "Firebase Initialization Failed natively. Ensure google-services.json is mapped: $e",
    );
  }

  await initializeBackgroundService();

  runApp(const SafeRouteApp());
}

class SafeRouteApp extends StatelessWidget {
  const SafeRouteApp({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<AuthController>()) {
      Get.put(AuthController());
    }
    if (!Get.isRegistered<HeatmapController>()) {
      Get.put(HeatmapController(), permanent: true);
    }
    if (!Get.isRegistered<RiskController>()) {
      Get.put(RiskController(), permanent: true);
    }
    if (!Get.isRegistered<SosController>()) {
      Get.put(SosController(), permanent: true);
    }
    if (!Get.isRegistered<SosListenerController>()) {
      Get.put(SosListenerController());
    }
    if (!Get.isRegistered<RescueInviteController>()) {
      Get.put(RescueInviteController());
    }
    if (!Get.isRegistered<RescueStatsController>()) {
      Get.put(RescueStatsController());
    }
    return GetMaterialApp(
      title: 'SafeRoute',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: const AuthWrapper(),
    );
  }
}
