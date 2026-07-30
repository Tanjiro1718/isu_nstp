import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../config/api_config.dart';
import '../services/notification_service.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  // --- ISU Theme Colors ---
  static const Color isuGreen = Color(0xFF006837);
  static const Color isuDarkGreen = Color(0xFF004D25);

  // Form & Input Controllers
  final _formKey = GlobalKey<FormState>();
  final _idNumberController = TextEditingController();
  final _courseSectionController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _otpController = TextEditingController();

  // State variables
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isWaitingForOtp = false;

  File? _idImageFile;
  final ImagePicker _picker = ImagePicker();

  @override
  void dispose() {
    _idNumberController.dispose();
    _courseSectionController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  // --- Image Picker Logic ---
  Future<void> _pickImage() async {
    final XFile? pickedFile = await _picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      setState(() {
        _idImageFile = File(pickedFile.path);
      });
    }
  }

  // --- Step 1: Submit Registration Data & Request OTP ---
  Future<void> _handleRegister() async {
    if (!_formKey.currentState!.validate()) return;

    if (_idImageFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please upload the front picture of your ID.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 🟢 FETCH FCM TOKEN FOR PUSH NOTIFICATIONS
      String? fcmToken = await NotificationService().getDeviceToken();

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('${ApiConfig.baseUrl}/api/register/'),
      );

      // Add headers
      request.headers['ngrok-skip-browser-warning'] = 'true';

      // Text form fields payload
      request.fields['username'] = _idNumberController.text.trim();
      request.fields['course_and_section'] = _courseSectionController.text.trim();
      request.fields['email'] = _emailController.text.trim();
      request.fields['password'] = _passwordController.text;
      
      // 🟢 ATTACH FCM TOKEN TO MULTIPART FIELDS
      request.fields['fcm_token'] = fcmToken ?? '';

      // File payload
      request.files.add(await http.MultipartFile.fromPath(
        'id_picture_front',
        _idImageFile!.path,
      ));

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (response.statusCode == 201 || response.statusCode == 200) {
        setState(() {
          _isWaitingForOtp = true; // Switch UI to OTP step
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Registration details received! A verification code was sent to your email.'),
            backgroundColor: isuGreen,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Registration failed: ${response.body}'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Network Error: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // --- Step 2: Submit OTP Code ---
  Future<void> _handleVerifyOtp() async {
    if (_otpController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter the verification code.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/verify-code/'),
        headers: {
          'Content-Type': 'application/json',
          'ngrok-skip-browser-warning': 'true',
        },
        body: json.encode({
          'email': _emailController.text.trim().toLowerCase(),
          'otp_code': _otpController.text.trim(),
        }),
      );

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (response.statusCode == 200) {
        _showFinalSuccessDialog();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid or expired code. Try again.'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Network Error: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // --- Final Admin Approval Notice Dialog ---
  void _showFinalSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: isuGreen),
            SizedBox(width: 8),
            Text("Email Verified!"),
          ],
        ),
        content: const Text(
          "Your email was successfully verified.\n\n"
          "Your account is now pending Admin Approval. An administrator will review your submitted Student ID picture shortly.\n\n"
          "You will be notified once your account is activated.",
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx); // Close dialog
              Navigator.pop(context); // Go back to login screen
            },
            child: const Text('Back to Login', style: TextStyle(color: isuGreen, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(_isWaitingForOtp ? "Verify Email" : "Create Account"),
        backgroundColor: isuGreen,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Card(
            elevation: 4,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
              child: _isWaitingForOtp ? _buildOtpForm() : _buildRegistrationForm(),
            ),
          ),
        ),
      ),
    );
  }

  // =========================================================
  // WIDGET: OTP VERIFICATION FORM (Step 2)
  // =========================================================
  Widget _buildOtpForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.mark_email_read, size: 64, color: isuGreen),
        const SizedBox(height: 16),
        const Text(
          "Enter Verification Code",
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: isuDarkGreen),
        ),
        const SizedBox(height: 8),
        Text(
          "We sent a 6-digit code to\n${_emailController.text}",
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 32),

        TextField(
          controller: _otpController,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 8.0, fontWeight: FontWeight.bold),
          decoration: const InputDecoration(
            hintText: "000000",
            border: OutlineInputBorder(),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: isuGreen, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 32),

        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isuGreen,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _isLoading ? null : _handleVerifyOtp,
            child: _isLoading
                ? const CircularProgressIndicator(color: Colors.white)
                : const Text("VERIFY EMAIL", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: () {
            setState(() {
              _isWaitingForOtp = false; // Allow step back to fix email details
            });
          },
          child: const Text("Wait, I need to fix my email/details", style: TextStyle(color: Colors.grey)),
        )
      ],
    );
  }

  // =========================================================
  // WIDGET: REGISTRATION FORM (Step 1)
  // =========================================================
  Widget _buildRegistrationForm() {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person_add_alt_1_rounded, size: 64, color: isuGreen),
          const SizedBox(height: 16),
          const Text(
            "Student Registration",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: isuDarkGreen),
          ),
          const Text("Fill out the form to register for NSTP", style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 32),

          // 1. ID Number (Username)
          TextFormField(
            controller: _idNumberController,
            decoration: const InputDecoration(
              labelText: 'ID Number (Username)',
              hintText: 'e.g. 21-12345',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.badge, color: isuGreen),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: isuGreen, width: 2),
              ),
            ),
            validator: (value) => value!.trim().isEmpty ? 'ID Number is required.' : null,
          ),
          const SizedBox(height: 16),

          // 2. Course & Section
          TextFormField(
            controller: _courseSectionController,
            decoration: const InputDecoration(
              labelText: 'Course & Section',
              hintText: 'e.g. BSIT-NS 1A',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.school, color: isuGreen),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: isuGreen, width: 2),
              ),
            ),
            validator: (value) => value!.trim().isEmpty ? 'Course & Section is required.' : null,
          ),
          const SizedBox(height: 16),

          // 3. ISU Email
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Verified ISU Email',
              hintText: 'name@isu.edu.ph',
              helperText: 'Must end with @isu.edu.ph',
              helperStyle: TextStyle(color: isuGreen),
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.email, color: isuGreen),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: isuGreen, width: 2),
              ),
            ),
            validator: (value) {
              final email = value!.trim();
              if (email.isEmpty) return 'Email is required.';
              if (!email.endsWith('@isu.edu.ph')) {
                return 'Only @isu.edu.ph emails are allowed.';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // 4. Password
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
                icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, color: Colors.grey),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            validator: (value) => value!.length < 6 ? 'Password must be at least 6 characters.' : null,
          ),
          const SizedBox(height: 16),

          // 5. Confirm Password
          TextFormField(
            controller: _confirmPasswordController,
            obscureText: _obscureConfirmPassword,
            decoration: InputDecoration(
              labelText: 'Confirm Password',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.lock_reset, color: isuGreen),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: isuGreen, width: 2),
              ),
              suffixIcon: IconButton(
                icon: Icon(_obscureConfirmPassword ? Icons.visibility_off : Icons.visibility, color: Colors.grey),
                onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
              ),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please confirm your password.';
              }
              if (value != _passwordController.text) {
                return 'Passwords do not match.';
              }
              return null;
            },
          ),
          const SizedBox(height: 24),

          // 6. ID Picture Upload Box
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                const Text(
                  "Upload Front of Student ID",
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                _idImageFile != null
                    ? Stack(
                        alignment: Alignment.topRight,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              _idImageFile!,
                              height: 120,
                              width: double.infinity,
                              fit: BoxFit.cover,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.cancel, color: Colors.red),
                            onPressed: () => setState(() => _idImageFile = null),
                          )
                        ],
                      )
                    : ElevatedButton.icon(
                        onPressed: _pickImage,
                        icon: const Icon(Icons.upload_file),
                        label: const Text("Select Image"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isuGreen.withValues(alpha: 0.1),
                          foregroundColor: isuGreen,
                          elevation: 0,
                        ),
                      ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Submit / Continue Button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isuGreen,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: _isLoading ? null : _handleRegister,
              child: _isLoading
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text("CONTINUE", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}