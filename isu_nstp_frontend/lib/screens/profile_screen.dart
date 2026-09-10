import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/user_model.dart';
import '../services/session_service.dart';
import '../widgets/change_password_flow.dart';

/// Profile / account details, shared by every role (student, instructor,
/// director, admin).
///
/// Change Password lives in the shared [ChangePasswordFlow] widget so students
/// and instructors get the same flow from their dashboard profile details.
class ProfileScreen extends StatefulWidget {
  final UserModel user;

  const ProfileScreen({super.key, required this.user});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const Color isuGreen = Color(0xFF006837);
  static const Color isuDarkGreen = Color(0xFF004D25);

  /// Mutable copy of the signed-in user so profile edits can refresh the UI
  /// (and persisted session) without a full re-login.
  late UserModel _user = widget.user;

  // ---------------------------------------------------------------- API calls

  /// Submits a password-confirmed account deletion request.
  /// Returns null on success, or the error message to display.
  Future<String?> _requestAccountDeletion(
    String password,
    String email,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse(
                '${ApiConfig.baseUrl}/api/account-deletion/request/'),
            headers: const {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: json.encode({
              'user_id': _user.id,
              'password': password,
              'email': email,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 201) return null;

      final data = json.decode(response.body) as Map<String, dynamic>;
      return data['detail']?.toString() ?? 'Could not submit your request.';
    } on TimeoutException {
      return 'Connection timed out. Please try again.';
    } catch (e) {
      return 'Failed to reach server: $e';
    }
  }

  // -------------------------------------------------------- Edit profile flow

  /// Submits the profile edit. Returns null on success, or the error message.
  Future<String?> _submitProfileEdit(
    String currentPassword,
    String email,
    String firstName,
    String middleName,
    String lastName,
    String phoneNumber,
    String department,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/edit-profile/'),
            headers: const {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: json.encode({
              'user_id': _user.id,
              'current_password': currentPassword,
              'email': email.trim(),
              'first_name': firstName.trim(),
              'middle_name': middleName.trim(),
              'last_name': lastName.trim(),
              'phone_number': phoneNumber.trim(),
              'department': department.trim(),
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        if (data['user'] is Map<String, dynamic>) {
          final updated = UserModel.fromJson(data['user'] as Map<String, dynamic>);
          setState(() => _user = updated);
          await SessionService.saveUser(updated);
        }
        return null;
      }

      Map<String, dynamic> data = {};
      try {
        data = json.decode(response.body) as Map<String, dynamic>;
      } catch (_) {}

      // DRF field errors arrive as a map of field -> [message].
      if (data.values.any((v) => v is List && v.isNotEmpty)) {
        final first = data.entries.firstWhere(
          (e) => e.value is List && (e.value as List).isNotEmpty,
        );
        final messages = first.value as List;
        return '${first.key}: ${messages.first}';
      }
      return data['detail']?.toString() ?? 'Could not update your profile.';
    } on TimeoutException {
      return 'Connection timed out. Please try again.';
    } catch (e) {
      return 'Failed to reach server: $e';
    }
  }

  /// Opens the edit-profile sheet. Shown only for non-student roles.
  void _editProfile() {
    final formKey = GlobalKey<FormState>();
    final firstNameController = TextEditingController(text: _user.firstName);
    final middleNameController = TextEditingController(text: _user.middleName);
    final lastNameController = TextEditingController(text: _user.lastName);
    final emailController = TextEditingController(text: _user.email);
    final phoneController = TextEditingController(text: _user.phoneNumber);
    final departmentController = TextEditingController(text: _user.department);
    final passwordController = TextEditingController();

    final isInstructor = _user.role.toLowerCase() == 'instructor';

    bool busy = false;
    bool obscure = true;
    String? error;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> submit() async {
              final messenger = ScaffoldMessenger.of(context);
              if (!formKey.currentState!.validate()) return;
              setSheetState(() {
                error = null;
                busy = true;
              });

              final failure = await _submitProfileEdit(
                passwordController.text,
                emailController.text,
                firstNameController.text,
                middleNameController.text,
                lastNameController.text,
                phoneController.text,
                departmentController.text,
              );
              setSheetState(() => busy = false);

              if (failure == null) {
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Profile updated successfully'),
                    backgroundColor: isuGreen,
                  ),
                );
              } else {
                setSheetState(() => error = failure);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.edit_outlined, color: isuGreen),
                          const SizedBox(width: 8),
                          const Text(
                            'Edit Profile',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isuDarkGreen,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed:
                                busy ? null : () => Navigator.pop(sheetContext),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      if (error != null)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            error!,
                            style: TextStyle(
                              color: Colors.red.shade700,
                              fontSize: 13,
                            ),
                          ),
                        ),

                      TextFormField(
                        controller: firstNameController,
                        decoration: const InputDecoration(
                          labelText: 'First Name',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'First name is required.'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: middleNameController,
                        decoration: const InputDecoration(
                          labelText: 'Middle Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: lastNameController,
                        decoration: const InputDecoration(
                          labelText: 'Last Name',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Last name is required.'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) {
                          final value = (v ?? '').trim();
                          if (value.isEmpty) return 'Email is required.';
                          if (!value.contains('@')) return 'Enter a valid email.';
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone Number',
                          hintText: 'e.g. 09171234567',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (isInstructor) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: departmentController,
                          decoration: const InputDecoration(
                            labelText: 'Department',
                            hintText: 'ROTC / CWTS / LTS',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: passwordController,
                        obscureText: obscure,
                        decoration: InputDecoration(
                          labelText: 'Current Password',
                          helperText:
                              'Confirm your password so the details can be saved',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(obscure
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setSheetState(
                                () => obscure = !obscure),
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty)
                            ? 'Current password is required.'
                            : null,
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isuGreen,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: busy ? null : submit,
                          child: busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Save Changes',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------- Delete account

  /// First asks for an explicit password-confirmed confirmation in a sheet,
  /// then submits the account deletion request.
  void _showDeleteAccountSheet() {
    final passwordController = TextEditingController();
    final emailController = TextEditingController(text: _user.email);
    final formKey = GlobalKey<FormState>();

    bool busy = false;
    bool obscure = true;
    String? error;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> submit() async {
              if (!formKey.currentState!.validate()) return;
              setSheetState(() {
                error = null;
                busy = true;
              });

              final failure = await _requestAccountDeletion(
                passwordController.text,
                emailController.text.trim(),
              );
              setSheetState(() => busy = false);

              if (failure == null) {
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                _showDeletionRequestedDialog();
              } else {
                setSheetState(() => error = failure);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.delete_forever, color: Colors.red),
                        const SizedBox(width: 8),
                        const Text(
                          'Delete Account',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.red,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed:
                              busy ? null : () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    if (error != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                color: Colors.red.shade700, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                error!,
                                style: TextStyle(
                                    color: Colors.red.shade700, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),

                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: const Text(
                        'This will permanently delete your account and the '
                        'personal data associated with it after review by an '
                        'NSTP administrator. Attendance records that must be '
                        'kept for institutional purposes may be retained in '
                        'anonymized form. This action cannot be undone.',
                        style: TextStyle(fontSize: 13, color: Colors.red),
                      ),
                    ),

                    const SizedBox(height: 16),

                    Form(
                      key: formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextFormField(
                            controller: emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: const InputDecoration(
                              labelText: 'Account Email',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.email, color: isuGreen),
                            ),
                            validator: (v) {
                              final email = (v ?? '').trim();
                              if (email.isEmpty) return 'Enter your email.';
                              if (!email.contains('@')) {
                                return 'Enter a valid email address.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: passwordController,
                            obscureText: obscure,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              border: const OutlineInputBorder(),
                              prefixIcon:
                                  const Icon(Icons.lock_outline, color: isuGreen),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  obscure
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                  color: Colors.grey,
                                ),
                                onPressed: () =>
                                    setSheetState(() => obscure = !obscure),
                              ),
                            ),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'Enter your password to confirm.'
                                : null,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: busy ? null : submit,
                        icon: busy
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.delete_forever),
                        label: Text(
                          busy ? 'Submitting...' : 'Request Account Deletion',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showDeletionRequestedDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.hourglass_top, color: isuGreen),
            SizedBox(width: 8),
            Text('Request Submitted', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: const Text(
          'Your account deletion request has been submitted. An NSTP '
          'administrator will review it, and you will be notified once your '
          'account has been deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(color: isuGreen)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------- Widgets

  Widget _detailTile(IconData icon, String label, String? value) {
    final display = (value == null || value.trim().isEmpty) ? '--' : value;
    return ListTile(
      dense: true,
      leading: Icon(icon, color: isuGreen, size: 20),
      title: Text(label,
          style: const TextStyle(fontSize: 12, color: Colors.grey)),
      subtitle: Text(
        display,
        style: const TextStyle(
            fontSize: 15, fontWeight: FontWeight.w500, color: Colors.black87),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    final roleLabel = user.role.isEmpty
        ? 'Student'
        : user.role[0].toUpperCase() + user.role.substring(1);

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text('My Profile'),
        backgroundColor: isuGreen,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- Identity header ---
          Card(
            elevation: 2,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 38,
                    backgroundColor: isuGreen.withValues(alpha: 0.12),
                    child: Text(
                      (user.displayName.isNotEmpty
                              ? user.displayName[0]
                              : user.username.isNotEmpty
                                  ? user.username[0]
                                  : '?')
                          .toUpperCase(),
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        color: isuDarkGreen,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    user.displayName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: isuDarkGreen,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Chip(
                    label: Text(roleLabel),
                    backgroundColor: isuGreen.withValues(alpha: 0.12),
                    labelStyle: const TextStyle(
                      color: isuDarkGreen,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                    side: BorderSide.none,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // --- Account details ---
          Card(
            elevation: 2,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    'Account Details',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: isuDarkGreen),
                  ),
                ),
                _detailTile(Icons.person_outline, 'Username', user.username),
                _detailTile(Icons.email_outlined, 'Email', user.email),
                // Student-only fields stay hidden for staff accounts.
                if (user.role.toLowerCase() == 'student') ...[
                  _detailTile(Icons.badge_outlined, 'Student ID', user.studentId),
                  _detailTile(Icons.school_outlined, 'Course & Section',
                      user.courseAndSection),
                  _detailTile(
                      Icons.category_outlined, 'Component', user.component),
                ] else ...[
                  _detailTile(Icons.person_outline, 'Full Name', user.displayName),
                  if (user.phoneNumber != null && user.phoneNumber!.isNotEmpty)
                    _detailTile(Icons.phone_outlined, 'Phone', user.phoneNumber),
                  if (user.department != null && user.department!.isNotEmpty)
                    _detailTile(Icons.apartment_outlined, 'Department',
                        user.department),
                ],
                // Instructor / director / admin can maintain their own details.
                // Students are governed by the NSTP office, so they get no edit.
                if (user.role.toLowerCase() != 'student')
                  ListTile(
                    leading: const Icon(Icons.edit_outlined, color: isuGreen),
                    title: const Text('Edit Profile',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                      'Update your name, phone number, and email',
                      style: TextStyle(fontSize: 12),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _editProfile,
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // --- Security ---
          Card(
            elevation: 2,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    'Security',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: isuDarkGreen),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.lock_reset, color: isuGreen),
                  title: const Text('Change Password'),
                  subtitle: const Text(
                    'Confirm it is you on this device, then verify with your '
                    'current password and the code sent to your phone',
                    style: TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => ChangePasswordFlow.show(context, _user),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_forever, color: Colors.red),
                  title: const Text(
                    'Delete Account',
                    style: TextStyle(color: Colors.red),
                  ),
                  subtitle: const Text(
                    'Request deletion of your account and the data associated '
                    'with it. An NSTP administrator will process the request.',
                    style: TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showDeleteAccountSheet,
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
