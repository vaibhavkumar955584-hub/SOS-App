import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class VigilBrandHeader extends StatelessWidget {
  final double logoHeight;
  final bool showBadgeContainer;
  final bool showSubtitle;
  final String? customSubtitle;

  const VigilBrandHeader({
    super.key,
    this.logoHeight = 30,
    this.showBadgeContainer = true,
    this.showSubtitle = false,
    this.customSubtitle,
  });

  @override
  Widget build(BuildContext context) {
    Widget logoCore = Image.asset(
      'assets/vigil_rect_logo.png',
      height: logoHeight,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => _buildFallbackLogo(),
    );

    if (showBadgeContainer) {
      logoCore = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: AppColors.safetyGreen.withValues(alpha: 0.5),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.safetyGreen.withValues(alpha: 0.35),
              blurRadius: 10,
              spreadRadius: 1,
            ),
          ],
        ),
        child: logoCore,
      );
    }

    if (!showSubtitle) {
      return logoCore;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        logoCore,
        if (showSubtitle) ...[
          const SizedBox(height: 8),
          Text(
            customSubtitle ?? 'Vulnerability Intelligence & Geo Safety',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFallbackLogo() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: AppColors.safetyGreen.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.shield_rounded,
            color: AppColors.safetyGreen,
            size: 20,
          ),
        ),
        const SizedBox(width: 8),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [AppColors.safetyGreen, AppColors.softCyan],
          ).createShader(bounds),
          child: Text(
            'VIGIL',
            style: TextStyle(
              fontFamily: 'Manrope',
              fontSize: logoHeight * 0.6,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              letterSpacing: 1.8,
            ),
          ),
        ),
      ],
    );
  }
}
