import 'dart:async'; // ⏱️ Handles TimeoutExceptions
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../models/user_model.dart';
import '../config/api_config.dart';
import '../services/notification_service.dart';
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

  // --- Login Request Handler ---
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

      // Guard against mounted context errors after async gap
      if (!mounted) return;

      setState(() => _isLoading = false);

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(response.body);

        // 🛡️ Safe Extraction: Handle both nested 'user' key or direct user object
        final Map<String, dynamic> userMap =
            (responseData.containsKey('user') && responseData['user'] != null)
                ? responseData['user'] as Map<String, dynamic>
                : responseData;

        // Construct UserModel safely using null-safe constructor
        final user = UserModel.fromJson(userMap);

        _showSnackBar('Welcome back, ${user.username}!', isuGreen);

        // Bind this device to the account so password codes and other alerts
        // can be pushed. Fire-and-forget: a failure here must not block login.
        _registerDeviceToken(user.id);

        // Role-based Navigation Routing
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

  /// Sends this device's FCM token to the backend for [userId].
  ///
  /// Registration only captured a token at signup, which left every existing
  /// account (and every instructor/director/admin) without one. Doing it on
  /// each login also keeps the token fresh after a reinstall.
  Future<void> _registerDeviceToken(int userId) async {
    try {
      final token = await NotificationService().getDeviceToken();
      if (token == null || token.isEmpty) return;

      await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/device-token/'),
            headers: const {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: jsonEncode({'user_id': userId, 'fcm_token': token}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      // Push is a nice-to-have; the email fallback still delivers codes.
      debugPrint('Could not register device token: $e');
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

  // --- API 2: Verify code and set new password ---
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
  void _showForgotPasswordDialog() {
    final emailController = TextEditingController();
    final codeController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();

    final step1FormKey = GlobalKey<FormState>();
    final step2FormKey = GlobalKey<FormState>();

    int currentStep = 1;
    bool isSubmitting = false;
    bool obscureNewPassword = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void closeDialog() {
              emailController.dispose();
              codeController.dispose();
              newPasswordController.dispose();
              confirmPasswordController.dispose();
              Navigator.pop(dialogContext);
            }

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
                                validator: (v) {
                                  if (v!.isEmpty) return 'Enter a new password.';
                                  if (v.length < 6) return 'Must be at least 6 characters.';
                                  return null;
                                },
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
                        // OFFICIAL ISU SEAL LOGO
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
            ],
          ),
        ),
      ),
    );
  }
}