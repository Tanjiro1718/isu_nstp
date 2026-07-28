import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../config/api_config.dart';
import '../../models/user_model.dart';
import '../login_screen.dart';
import 'student_checkin_screen.dart';

class StudentDashboard extends StatefulWidget {
  final UserModel user;
  const StudentDashboard({super.key, required this.user});

  @override
  State<StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<StudentDashboard> {
  final String currentSessionUrl = ApiConfig.currentSessionUrl;
  bool _isOpeningCheckIn = false;
  late UserModel _currentUser;

  @override
  void initState() {
    super.initState();
    _currentUser = widget.user;
  }

  Future<void> _openCurrentSessionCheckIn() async {
    setState(() => _isOpeningCheckIn = true);

    try {
      final response = await http.get(Uri.parse(currentSessionUrl));

      if (!mounted) return;
      setState(() => _isOpeningCheckIn = false);

      if (response.statusCode != 200) {
        _showSnackBar(
          'No active attendance session found. Ask your instructor to start one.',
          Colors.red,
        );
        return;
      }

      final data = json.decode(response.body);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => StudentCheckInScreen(
            user: widget.user,
            sessionId: data['id'],
            targetLat: double.parse(data['target_latitude'].toString()),
            targetLng: double.parse(data['target_longitude'].toString()),
            allowedRadiusMeters: data['radius_meters'],
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isOpeningCheckIn = false);
      _showSnackBar('Unable to load active session: $e', Colors.red);
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Student Dashboard"),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'Profile',
            onPressed: _showProfileEditor,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (context) => const LoginScreen()),
                (route) => false,
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: ListView(
          children: [
            Text(
              "Welcome, ${_currentUser.username}!",
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "Ready for class? Check in below.",
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 32),
            _buildDashboardCard(
              context,
              title: 'Check-In to Class',
              subtitle: _isOpeningCheckIn
                  ? 'Loading active session...'
                  : 'Use GPS to mark your attendance',
              icon: Icons.location_on,
              iconColor: Colors.green,
              onTap: _isOpeningCheckIn ? null : _openCurrentSessionCheckIn,
            ),
            const SizedBox(height: 16),
            _buildDashboardCard(
              context,
              title: 'My Attendance Record',
              subtitle: 'View your past check-ins and absences',
              icon: Icons.history_edu,
              iconColor: Colors.orange,
              onTap: () {
                _showSnackBar(
                  'Attendance History screen coming soon!',
                  Colors.blue,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showProfileEditor() {
    final courseController = TextEditingController(text: _currentUser.course ?? '');
    final studentIdController = TextEditingController(text: _currentUser.studentId ?? '');
    final sectionController = TextEditingController(text: _currentUser.section ?? '');
    final emailController = TextEditingController(text: _currentUser.email);
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Edit Profile'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: courseController,
                    decoration: const InputDecoration(
                      labelText: 'Course',
                      hintText: 'CWTS / LTS / ROTC',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: studentIdController,
                    decoration: const InputDecoration(
                      labelText: 'ID Number',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: sectionController,
                    decoration: const InputDecoration(
                      labelText: 'Section',
                      hintText: 'CWTS-1A',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      helperText: 'Must end with @isu.edu.ph',
                    ),
                    validator: (value) {
                      final email = value?.trim() ?? '';
                      if (email.isNotEmpty && !email.toLowerCase().endsWith('@isu.edu.ph')) {
                        return 'Email must end with @isu.edu.ph';
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
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;

                    final navigator = Navigator.of(dialogContext);

                final updated = await _saveProfileChanges(
                  course: courseController.text.trim(),
                  studentId: studentIdController.text.trim(),
                  section: sectionController.text.trim(),
                  email: emailController.text.trim(),
                );

                if (!mounted) return;

                if (updated) {
                      navigator.pop();
                  _showSnackBar('Profile updated successfully.', Colors.green);
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _saveProfileChanges({
    required String course,
    required String studentId,
    required String section,
    required String email,
  }) async {
    try {
      final response = await http.patch(
        Uri.parse('${ApiConfig.usersUrl}${_currentUser.id}/'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'course': course,
          'student_id': studentId,
          'email': email,
          'section': section,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        setState(() {
          _currentUser = UserModel.fromJson(data);
        });
        return true;
      }

      _showSnackBar('Unable to update profile. Error ${response.statusCode}.', Colors.red);
      return false;
    } catch (e) {
      _showSnackBar('Network error while updating profile: $e', Colors.red);
      return false;
    }
  }

  Widget _buildDashboardCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required VoidCallback? onTap,
  }) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12.0),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: iconColor.withValues(alpha: 0.15),
              child: _isOpeningCheckIn && title == 'Check-In to Class'
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(icon, color: iconColor),
            ),
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            subtitle: Text(subtitle),
            trailing: const Icon(
              Icons.arrow_forward_ios,
              size: 16,
              color: Colors.grey,
            ),
          ),
        ),
      ),
    );
  }
}
