import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/auth_controller.dart';
import '../theme/app_colors.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();
  final _ec1Controller = TextEditingController();
  final _ec2Controller = TextEditingController();
  final _authController = AuthController.instance;

  bool _obscurePassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _phoneController.dispose();
    _ec1Controller.dispose();
    _ec2Controller.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final phone = _phoneController.text.trim();
    final ec1 = _ec1Controller.text.trim();
    final ec2 = _ec2Controller.text.trim();

    if (name.isEmpty || email.isEmpty || password.isEmpty || phone.isEmpty || ec1.isEmpty || ec2.isEmpty) {
      Get.snackbar(
        "Missing Details",
        "Please fill in all fields including emergency contacts.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: AppColors.signalRed,
        colorText: Colors.white,
      );
      return;
    }

    if (!email.contains('@') || !email.contains('.')) {
      Get.snackbar(
        "Invalid Email",
        "Please enter a valid email address.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: AppColors.signalRed,
        colorText: Colors.white,
      );
      return;
    }

    if (password.length < 6) {
      Get.snackbar(
        "Weak Password",
        "Password must be at least 6 characters.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: AppColors.signalRed,
        colorText: Colors.white,
      );
      return;
    }

    await _authController.register(
      name,
      email,
      password,
      phone,
      ec1,
      ec2,
    );
  }

  InputDecoration _inputDecoration({
    required String label,
    required IconData prefixIcon,
    String? hint,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: AppColors.onSurfaceVariant),
      hintStyle: TextStyle(color: AppColors.onSurfaceVariant.withValues(alpha: 0.5)),
      prefixIcon: Icon(prefixIcon, color: AppColors.primary),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: AppColors.surfaceContainer,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.borderSubtle),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.borderSubtle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          "Create Account",
          style: TextStyle(color: AppColors.onSurface, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.onSurface),
          onPressed: () => Get.back(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Join VIGIL Safety Network',
                style: TextStyle(
                  color: AppColors.onSurface,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Set up your profile and emergency guardian contacts.',
                style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 13),
              ),
              const SizedBox(height: 24),

              // Full Name
              TextField(
                controller: _nameController,
                decoration: _inputDecoration(label: 'Full Name', prefixIcon: Icons.person_outline),
                style: const TextStyle(color: AppColors.onSurface),
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 14),

              // Email
              TextField(
                controller: _emailController,
                decoration: _inputDecoration(label: 'Email', prefixIcon: Icons.email_outlined),
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: AppColors.onSurface),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 14),

              // Password
              TextField(
                controller: _passwordController,
                decoration: _inputDecoration(
                  label: 'Password (min 6 characters)',
                  prefixIcon: Icons.lock_outline,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_off : Icons.visibility,
                      color: AppColors.onSurfaceVariant,
                    ),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                obscureText: _obscurePassword,
                style: const TextStyle(color: AppColors.onSurface),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 14),

              // Phone Number
              TextField(
                controller: _phoneController,
                decoration: _inputDecoration(
                  label: 'Your Phone Number',
                  prefixIcon: Icons.phone_outlined,
                  hint: '+91 9876543210',
                ),
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: AppColors.onSurface),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 24),

              // Emergency Contacts Section Header
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.shield_outlined, color: AppColors.primary, size: 22),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Emergency Guardian Contacts",
                            style: TextStyle(
                              color: AppColors.onSurface,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            "Alert SMS will be dispatched to these numbers during SOS.",
                            style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Contact 1
              TextField(
                controller: _ec1Controller,
                decoration: _inputDecoration(
                  label: 'Guardian Contact 1 (Phone)',
                  prefixIcon: Icons.contact_phone_outlined,
                  hint: '+91...',
                ),
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: AppColors.onSurface),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 14),

              // Contact 2
              TextField(
                controller: _ec2Controller,
                decoration: _inputDecoration(
                  label: 'Guardian Contact 2 (Phone)',
                  prefixIcon: Icons.contact_phone_outlined,
                  hint: '+91...',
                ),
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: AppColors.onSurface),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _signUp(),
              ),
              const SizedBox(height: 28),

              // Register Button with Loading Spinner
              Obx(() {
                final isBusy = _authController.isLoading.value;
                return SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 2,
                    ),
                    onPressed: isBusy ? null : _signUp,
                    child: isBusy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(AppColors.onPrimary),
                            ),
                          )
                        : const Text(
                            'Register & Activate Safety',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                  ),
                );
              }),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
