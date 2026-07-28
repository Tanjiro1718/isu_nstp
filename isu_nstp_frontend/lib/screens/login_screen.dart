import 'dart:convert';
import 'dart:async'; // ⏱️ Added to handle TimeoutExceptions
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../../models/user_model.dart';
import 'student/student_dashboard.dart';
import 'instructor/instructor_dashboard.dart';
import 'director/director_dashboard.dart';
import 'admin/admin_dashboard.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;

  final String loginUrl = ApiConfig.loginUrl;
  final String resetPasswordUrl = ApiConfig.resetPasswordUrl;

  // --- Login Request Handler ---
  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final response = await http
          .post(
            Uri.parse(loginUrl),
            headers: {
              'ngrok-skip-browser-warning': 'true',
            },
            body: {
              'username': _usernameController.text.trim(),
              'password': _passwordController.text,
            },
          )
          .timeout(const Duration(seconds: 7)); // ⏱️ Added timeout limit

      setState(() => _isLoading = false);

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(response.body);
        final user = UserModel.fromJson(responseData['user']);

        _showSnackBar('Welcome back, ${user.username}!', Colors.green);

        // Role-based Navigation Routing
        if (user.role.toLowerCase() == 'admin') {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => AdminDashboard(user: user)),
          );
        } else if (user.role.toLowerCase() == 'instructor') {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => InstructorDashboard(user: user),
            ),
          );
        } else if (user.role.toLowerCase() == 'director') {
          // 🔴 ADDED ROUTING FOR DIRECTOR HERE
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => DirectorDashboard(user: user),
            ),
          );
        } else if (user.role.toLowerCase() == 'student') {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => StudentDashboard(user: user),
            ),
          );
        } else {
          _showSnackBar('Unknown role: ${user.role}', Colors.red);
        }
      } else {
        _showSnackBar(_getLoginErrorMessage(response), Colors.red);
      }
    } on TimeoutException catch (_) {
      setState(() => _isLoading = false);
      _showSnackBar(
        'Connection timed out. Check if your backend is running or your IP changed.',
        Colors.red,
      );
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Network Error: $e', Colors.red);
    }
  }

  String _getLoginErrorMessage(http.Response response) {
    try {
      final Map<String, dynamic> errorData = json.decode(response.body);
      return errorData['message'] ??
          errorData['detail'] ??
          errorData['non_field_errors']?[0] ??
          'Invalid credentials.';
    } catch (_) {
      return 'Server returned an error page. Check Django terminal for details.';
    }
  }

  // --- Password Recovery (Forgot Password) Handler ---
  Future<void> _handlePasswordRecovery(String username, String email) async {
    try {
      final response = await http
          .post(
            Uri.parse(resetPasswordUrl),
            headers: {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: json.encode({'username': username, 'email': email}),
          )
          .timeout(const Duration(seconds: 7)); // ⏱️ Added timeout limit

      if (response.statusCode == 200) {
        _showSuccessDialog(
          "Recovery Initiated",
          "A password reset link or instructions have been sent to your verified institutional email: $email.",
        );
      } else {
        final Map<String, dynamic> errorData = json.decode(response.body);
        _showSnackBar(
          errorData['detail'] ?? 'No active account found with these details.',
          Colors.red,
        );
      }
    } on TimeoutException catch (_) {
      _showSnackBar('Password recovery request timed out.', Colors.red);
    } catch (e) {
      _showSnackBar(
        'Network error occurred during password recovery.',
        Colors.red,
      );
    }
  }

  // UI Dialog to Trigger Verified Email Password Reset
  void _showForgotPasswordDialog() {
    final recoveryUsernameController = TextEditingController();
    final recoveryEmailController = TextEditingController();
    final dialogFormKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.lock_reset, color: Colors.blueAccent),
              SizedBox(width: 8),
              Text('Account Recovery'),
            ],
          ),
          content: Form(
            key: dialogFormKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Enter your details below to request a password reset link.",
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: recoveryUsernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    validator: (v) => v!.trim().isEmpty
                        ? 'Please enter your username.'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: recoveryEmailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Verified ISU Email',
                      hintText: 'name@isu.edu.ph',
                      helperText: 'Must end with @isu.edu.ph',
                      helperStyle: TextStyle(color: Colors.blueAccent),
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.email),
                    ),
                    validator: (v) {
                      final email = v!.trim();
                      if (email.isEmpty) {
                        return 'Please enter your email.';
                      }
                      if (!email.endsWith('@isu.edu.ph')) {
                        return 'Must be an official @isu.edu.ph email.';
                      }
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
              ),
              onPressed: () {
                if (dialogFormKey.currentState!.validate()) {
                  final username = recoveryUsernameController.text.trim();
                  final email = recoveryEmailController.text.trim();
                  Navigator.pop(context); // Close recovery dialog
                  _handlePasswordRecovery(username, email);
                }
              },
              child: const Text(
                'Reset Password',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  void _showSuccessDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.green,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Card(
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
                    // Brand Logo/Header
                    const Icon(
                      Icons.security,
                      size: 64,
                      color: Colors.blueAccent,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "ISU NSTP Portal",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
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
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (value) =>
                          value!.isEmpty ? 'Username is required.' : null,
                    ),
                    const SizedBox(height: 16),

                    // Password field
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility,
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
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Login Button
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: _isLoading ? null : _handleLogin,
                        child: _isLoading
                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )
                            : const Text(
                                "LOGIN",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
