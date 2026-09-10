import 'dart:async'; // ⏱️ Handles TimeoutExceptions
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/user_model.dart';
import '../config/api_config.dart';
import '../services/device_token_service.dart';
import '../services/session_service.dart';
import '../utils/password_policy.dart';
import '../widgets/password_strength_meter.dart';
import 'admin/admin_dashboard.dart';
import 'director/director_dashboard.dart';
import 'instructor/instructor_dashboard.dart';
import 'register_screen.dart';
import 'student/student_dashboard.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // --- ISU Theme Colors ---
  static const Color isuGreen = Color(0xFF006837); // Official ISU Green
  static const Color isuDarkGreen = Color(0xFF004D25);

  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;

  final String loginUrl = ApiConfig.loginUrl;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final response = await http
          .post(
            Uri.parse(loginUrl),
            headers: {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: jsonEncode({
              'username': _usernameController.text.trim(),
              'password': _passwordController.text,
            }),
          )
          .timeout(const Duration(seconds: 7));

      if (!mounted) return;

      setState(() => _isLoading = false);

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(response.body);

        final Map<String, dynamic> userMap =
            (responseData.containsKey('user') && responseData['user'] != null)
                ? responseData['user'] as Map<String, dynamic>
                : responseData;

        var user = UserModel.fromJson(userMap);

        // First-use consent gate. Legacy / staff accounts created before the
        // Privacy Policy and Terms existed have null timestamps, so the app
        // asks once before opening the dashboard and stamps acceptance on
        // the server. Declining keeps the user on the login screen.
        if (!user.hasAcceptedPolicies) {
          final agreed = await _showConsentSheet();
          if (!agreed) {
            await SessionService.clear();
            _showSnackBar(
              'You need to accept the Privacy Policy and Terms & Conditions to continue.',
              Colors.red,
            );
            if (!mounted) return;
            setState(() => _isLoading = false);
            return;
          }

          final updatedUser = await _submitConsent(user, _passwordController.text);
          if (updatedUser == null) {
            if (!mounted) return;
            setState(() => _isLoading = false);
            return;
          }
          user = updatedUser;
        }

        await SessionService.saveUser(user);
        if (!mounted) return;

        _showSnackBar('Welcome back, ${user.username}!', isuGreen);

        DeviceTokenService.register(user.id);

        Widget destination;
        switch (user.role.toLowerCase()) {
          case 'admin':
            destination = AdminDashboard(user: user);
            break;
          case 'instructor':
            destination = InstructorDashboard(user: user);
            break;
          case 'director':
            destination = DirectorDashboard(user: user);
            break;
          case 'student':
            destination = StudentDashboard(user: user);
            break;
          default:
            _showSnackBar('Unknown role: ${user.role}', Colors.red);
            return;
        }

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => destination),
        );
      } else {
        _showSnackBar(_getLoginErrorMessage(response), Colors.red);
      }
    } on TimeoutException catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar(
        'Connection timed out. Check if your backend is running or your IP changed.',
        Colors.red,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar('Network Error: $e', Colors.red);
    }
  }


  String _getLoginErrorMessage(http.Response response) {
    try {
      final Map<String, dynamic> errorData = json.decode(response.body);
      return errorData['message'] ??
          errorData['detail'] ??
          errorData['error'] ??
          errorData['non_field_errors']?[0] ??
          'Invalid credentials.';
    } catch (_) {
      return 'Server returned an error page. Check Django terminal for details.';
    }
  }

  // --- API 1: Request password reset code (push notification + email) ---
  Future<bool> _sendVerificationCode(String email) async {
    try {
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/password-reset/request-code/'),
            headers: {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: json.encode({'email': email}),
          )
          .timeout(const Duration(seconds: 7));

      if (!mounted) return false;

      if (response.statusCode == 200) {
        return true;
      } else {
        final Map<String, dynamic> errorData = json.decode(response.body);
        _showSnackBar(
          errorData['detail'] ?? 'Could not send code at this time.',
          Colors.red,
        );
        return false;
      }
    } on TimeoutException catch (_) {
      if (!mounted) return false;
      _showSnackBar('Connection timed out. Please try again.', Colors.red);
      return false;
    } catch (e) {
      if (!mounted) return false;
      _showSnackBar('Failed to reach server: $e', Colors.red);
      return false;
    }
  }

  Future<bool> _confirmPasswordReset(
    String email,
    String code,
    String newPassword,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/password-reset/confirm/'),
            headers: {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: json.encode({
              'email': email,
              'code': code,
              'new_password': newPassword,
            }),
          )
          .timeout(const Duration(seconds: 7));

      if (!mounted) return false;

      if (response.statusCode == 200) {
        return true;
      } else {
        final Map<String, dynamic> errorData = json.decode(response.body);
        _showSnackBar(
          errorData['detail'] ?? 'Invalid code or reset failed.',
          Colors.red,
        );
        return false;
      }
    } on TimeoutException catch (_) {
      if (!mounted) return false;
      _showSnackBar('Connection timed out. Please try again.', Colors.red);
      return false;
    } catch (e) {
      if (!mounted) return false;
      _showSnackBar('Failed to reach server: $e', Colors.red);
      return false;
    }
  }

  // --- Multi-Step Password Reset Dialog (push notification + email) ---
  Future<void> _showForgotPasswordDialog() async {
    final emailController = TextEditingController();
    final codeController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();

    final step1FormKey = GlobalKey<FormState>();
    final step2FormKey = GlobalKey<FormState>();

    int currentStep = 1;
    bool isSubmitting = false;
    bool obscureNewPassword = true;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // Only closes the route. Disposing the controllers here would kill
            // them while the TextFields still depend on them, which trips the
            // '_dependents.isEmpty' assertion - they are disposed below once
            // the dialog has fully gone.
            void closeDialog() => Navigator.pop(dialogContext);

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  Icon(
                    currentStep == 1 ? Icons.lock_reset : Icons.verified_user,
                    color: isuGreen,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    currentStep == 1 ? 'Reset Password' : 'Enter Code',
                    style: const TextStyle(fontSize: 18),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 320,
                  child: currentStep == 1
                      ? Form(
                          key: step1FormKey,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "Enter your official @isu.edu.ph email. A 6-digit code will be sent via push notification to your phone and to your inbox.",
                                style: TextStyle(fontSize: 13, color: Colors.grey),
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: emailController,
                                keyboardType: TextInputType.emailAddress,
                                decoration: const InputDecoration(
                                  labelText: 'Verified ISU Email',
                                  hintText: 'user@isu.edu.ph',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.email, color: isuGreen),
                                  focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: isuGreen, width: 2),
                                  ),
                                ),
                                validator: (v) {
                                  final email = v!.trim();
                                  if (email.isEmpty) {
                                    return 'Please enter your email.';
                                  }
                                  if (!email.endsWith('@isu.edu.ph')) {
                                    return 'Must end with @isu.edu.ph';
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ),
                        )
                      : Form(
                          key: step2FormKey,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "A 6-digit code was pushed to your device and emailed to:\n${emailController.text.trim()}",
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: isuDarkGreen,
                                ),
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: codeController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Verification Code',
                                  hintText: 'e.g., 123456',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.pin, color: isuGreen),
                                  focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: isuGreen, width: 2),
                                  ),
                                ),
                                validator: (v) => v!.trim().isEmpty
                                    ? 'Enter the 6-digit code.'
                                    : null,
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: newPasswordController,
                                obscureText: obscureNewPassword,
                                decoration: InputDecoration(
                                  labelText: 'New Password',
                                  border: const OutlineInputBorder(),
                                  prefixIcon: const Icon(Icons.lock_outline, color: isuGreen),
                                  focusedBorder: const OutlineInputBorder(
                                    borderSide: BorderSide(color: isuGreen, width: 2),
                                  ),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      obscureNewPassword
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                      color: Colors.grey,
                                    ),
                                    onPressed: () {
                                      setDialogState(() {
                                        obscureNewPassword = !obscureNewPassword;
                                      });
                                    },
                                  ),
                                ),
                                // Matches the rule the server enforces.
                                validator: PasswordPolicy.validate,
                                onChanged: (_) => setDialogState(() {}),
                              ),
                              PasswordStrengthMeter(
                                password: newPasswordController.text,
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: confirmPasswordController,
                                obscureText: obscureNewPassword,
                                decoration: const InputDecoration(
                                  labelText: 'Confirm Password',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.lock, color: isuGreen),
                                  focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: isuGreen, width: 2),
                                  ),
                                ),
                                validator: (v) {
                                  if (v != newPasswordController.text) {
                                    return 'Passwords do not match.';
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting ? null : closeDialog,
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isuGreen,
                  ),
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          if (currentStep == 1) {
                            if (step1FormKey.currentState!.validate()) {
                              setDialogState(() => isSubmitting = true);
                              final success = await _sendVerificationCode(
                                emailController.text.trim(),
                              );
                              setDialogState(() => isSubmitting = false);

                              if (success) {
                                setDialogState(() => currentStep = 2);
                              }
                            }
                          } else {
                            if (step2FormKey.currentState!.validate()) {
                              setDialogState(() => isSubmitting = true);
                              final success = await _confirmPasswordReset(
                                emailController.text.trim(),
                                codeController.text.trim(),
                                newPasswordController.text,
                              );
                              setDialogState(() => isSubmitting = false);

                              if (success) {
                                closeDialog();
                                _showSuccessDialog(
                                  "Password Reset Successful",
                                  "Your password has been changed. You can now log in with your new credentials.",
                                );
                              }
                            }
                          }
                        },
                  child: isSubmitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          currentStep == 1 ? 'Send Code' : 'Reset Password',
                          style: const TextStyle(color: Colors.white),
                        ),
                ),
              ],
            );
          },
        );
      },
    );

    emailController.dispose();
    codeController.dispose();
    newPasswordController.dispose();
    confirmPasswordController.dispose();
  }

  /// One-time consent sheet shown right after a successful login for accounts
  /// that have not accepted the Privacy Policy / Terms yet (legacy accounts).
  /// Returns true when the user tapped "I Agree".
  Future<bool> _showConsentSheet() async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Row(
              children: [
                Icon(Icons.gavel, color: isuGreen),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Accept Terms & Conditions',
                    style: TextStyle(
                      color: isuDarkGreen,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Before you continue using ISU NSTP Portal, please read and accept the following documents:",
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () => _openUrl(ApiConfig.privacyPolicyUri),
                    child: Row(
                      children: [
                        const Icon(Icons.policy_outlined, size: 18, color: isuGreen),
                        const SizedBox(width: 8),
                        Text(
                          'Privacy Policy',
                          style: const TextStyle(
                            fontSize: 14,
                            color: isuGreen,
                            fontWeight: FontWeight.w600,
                          ).copyWith(
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: () => _openUrl(ApiConfig.termsUri),
                    child: Row(
                      children: [
                        const Icon(Icons.article_outlined, size: 18, color: isuGreen),
                        const SizedBox(width: 8),
                        Text(
                          'Terms & Conditions',
                          style: const TextStyle(
                            fontSize: 14,
                            color: isuGreen,
                            fontWeight: FontWeight.w600,
                          ).copyWith(
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Not Now', style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: isuGreen),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('I Agree', style: TextStyle(color: Colors.white)),
              ),
            ],
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          ),
        ) ??
        false;
  }

  /// Stamps acceptance on the server using the same proof pattern as the other
  /// self-serve endpoints (user_id + current password, no token). Returns the
  /// updated user (with consent timestamps) or null when it failed.
  Future<UserModel?> _submitConsent(UserModel user, String password) async {
    if (!mounted) return null;
    try {
      final response = await http
          .post(
            Uri.parse(ApiConfig.consentUrl),
            headers: {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: json.encode({
              'user_id': user.id,
              'current_password': password,
            }),
          )
          .timeout(const Duration(seconds: 7));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        final userData = data['user'];
        final updated = UserModel.fromJson(
          userData is Map<String, dynamic> ? userData : null,
        );
        if (updated.id == user.id) return updated;
        // Fallback: server accepted but returned an unrecognizable user - keep
        // the local copy but assume consent went through.
        return user.copyWith(
          acceptedTermsAt: user.acceptedTermsAt ??
              DateTime.now().toUtc().toIso8601String(),
          acceptedPrivacyAt: user.acceptedPrivacyAt ??
              DateTime.now().toUtc().toIso8601String(),
        );
      }

      if (!mounted) return null;
      _showSnackBar('Could not save your acceptance. Please try again.', Colors.red);
      return null;
    } on TimeoutException catch (_) {
      if (!mounted) return null;
      _showSnackBar('Connection timed out. Please try again.', Colors.red);
      return null;
    } catch (e) {
      if (!mounted) return null;
      _showSnackBar('Failed to reach server: $e', Colors.red);
      return null;
    }
  }

  Future<void> _openUrl(Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      _showSnackBar('Could not open the link.', Colors.red);
    }
  }

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSuccessDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          title,
          style: const TextStyle(
            color: isuGreen,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(color: isuGreen)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 29, 176, 0),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24.0,
                    vertical: 32.0,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          'assets/images/isu_logo.png',
                          height: 90,
                          width: 90,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          "ISU NSTP Portal",
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: isuDarkGreen,
                          ),
                        ),
                        const Text(
                          "Sign in to access your dashboard",
                          style: TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 32),

                        // Username field
                        TextFormField(
                          controller: _usernameController,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.person_outline, color: isuGreen),
                            focusedBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: isuGreen, width: 2),
                            ),
                          ),
                          validator: (value) =>
                              value!.trim().isEmpty ? 'Username is required.' : null,
                        ),
                        const SizedBox(height: 16),

                        // Password field
                        TextFormField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.lock_outline, color: isuGreen),
                            focusedBorder: const OutlineInputBorder(
                              borderSide: BorderSide(color: isuGreen, width: 2),
                            ),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: Colors.grey,
                              ),
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                            ),
                          ),
                          validator: (value) =>
                              value!.isEmpty ? 'Password is required.' : null,
                        ),

                        // Forgot Password Action Button Link
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _showForgotPasswordDialog,
                            child: const Text(
                              "Forgot Password?",
                              style: TextStyle(
                                color: isuGreen,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Login Button
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isuGreen,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: _isLoading ? null : _handleLogin,
                          child: _isLoading
                              ? const SizedBox(
                                  height: 24,
                                  width: 24,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : const Text(
                                  "LOGIN",
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // REGISTER BUTTON ROW
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    "Don't have an account?",
                    style: TextStyle(fontSize: 15, color: Color.fromARGB(255, 255, 255, 255)),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const RegisterScreen(),
                        ),
                      );
                    },
                    child: const Text(
                      "Register",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color.fromARGB(255, 253, 255, 254),
                      ),
                    ),
                  ),
                ],
              ),

              // Legal footer - always visible so users can reach the docs.
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => _openUrl(ApiConfig.privacyPolicyUri),
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Privacy Policy',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color.fromARGB(255, 220, 255, 235),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                  const Text(
                    '·',
                    style: TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  TextButton(
                    onPressed: () => _openUrl(ApiConfig.termsUri),
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Terms & Conditions',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color.fromARGB(255, 220, 255, 235),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}