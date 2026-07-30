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

  // --- ISU Theme Colors ---
  static const Color isuGreen = Color(0xFF006837);

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
        backgroundColor: isuGreen,
        foregroundColor: Colors.white,
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'Profile Details',
            onPressed: _showProfileView,
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
              iconColor: isuGreen,
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

  // --- READ-ONLY PROFILE DIALOG ---
  void _showProfileView() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.account_circle, color: isuGreen, size: 28),
              SizedBox(width: 8),
              Text('Profile Details', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildReadOnlyTile(
                  icon: Icons.person,
                  label: 'Username',
                  value: _currentUser.username,
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.badge,
                  label: 'ID Number',
                  value: _currentUser.studentId ?? 'Not set',
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.school,
                  label: 'Course & Section',
                  value: _currentUser.courseAndSection ?? 'Not assigned',
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.email,
                  label: 'Email Address',
                  value: _currentUser.email,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text(
                'Close',
                style: TextStyle(color: isuGreen, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildReadOnlyTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: isuGreen),
        title: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          value.trim().isEmpty ? 'N/A' : value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
      ),
    );
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