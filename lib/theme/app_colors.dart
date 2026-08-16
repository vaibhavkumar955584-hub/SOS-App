import 'package:flutter/material.dart';

/// SafeRoute Precision Design System - Color Tokens
abstract class AppColors {
  // Brand & Safety Status Colors
  static const Color primary = Color(0xFF4BE277);
  static const Color primaryContainer = Color(0xFF22C55E);
  static const Color safetyGreen = Color(0xFF22C55E); // Safety Green
  static const Color onPrimary = Color(0xFF003915);

  static const Color signalRed = Color(0xFFEF4444); // Signal Red (Emergency)
  static const Color secondaryContainer = Color(0xFFA40217);
  static const Color onSecondary = Color(0xFF68000A);

  static const Color warningAmber = Color(0xFFF59E0B); // Amber Warning
  static const Color tertiaryContainer = Color(0xFFEF9900);

  static const Color softCyan = Color(0xFF38BDF8); // Utility/Telemetry Cyan

  // Surface & Neutral Layers (Tonal Layering)
  static const Color background = Color(0xFF121416); // Level 1: Lowest Layer
  static const Color surface = Color(0xFF121416);
  static const Color surfaceDim = Color(0xFF121416);
  static const Color surfaceContainerLow = Color(0xFF1A1C1E);
  static const Color surfaceContainer = Color(0xFF1E2022); // Level 2: Card Body
  static const Color surfaceContainerHigh = Color(0xFF282A2C); // Floating Elements
  static const Color surfaceContainerHighest = Color(0xFF333537);

  // Borders & Outlines
  static const Color outline = Color(0xFF869585);
  static const Color outlineVariant = Color(0xFF3D4A3D);
  static const Color borderSubtle = Color(0xFF2A2E32);

  // Typography & On-Surface
  static const Color onSurface = Color(0xFFE2E2E5);
  static const Color onSurfaceVariant = Color(0xFFBCCBB9);
  static const Color onBackground = Color(0xFFE2E2E5);
}
