import 'package:flutter/material.dart';
import '../../models/user_model.dart';
import '../../widgets/logout_helper.dart';
import '../profile_screen.dart';
import 'director_oversight_screen.dart';

class DirectorDashboard extends StatelessWidget {
  final UserModel user;
  
  const DirectorDashboard({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Director Portal"),
        backgroundColor: Colors.deepOrange.shade700, 
        foregroundColor: Colors.white,
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle),
            tooltip: 'My Profile',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ProfileScreen(user: user),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () => LogoutHelper.confirmAndLogout(context),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Welcome, Director ${user.username}!",
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const SizedBox(height: 4),
            const Text(
              "Oversee campus analytics, instructor compliance, and master records.",
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 32),

            // Button 1: Campus Analytics
            _buildDashboardCard(
              context,
              title: 'Campus Analytics Overview',
              subtitle: 'Attendance health for every class and component',
              icon: Icons.pie_chart,
              iconColor: Colors.deepOrange,
              onTap: () => _openOversight(context),
            ),

            const SizedBox(height: 16),

            // Button 2: Instructor Monitoring
            _buildDashboardCard(
              context,
              title: 'Instructor Compliance',
              subtitle: 'See which instructor handles each class and how they are doing',
              icon: Icons.assignment_ind,
              iconColor: Colors.blueGrey,
              // Same screen - it opens on the "By Instructor" tab.
              onTap: () => _openOversight(context, initialTab: 1),
            ),

            const SizedBox(height: 16),

            // Button 3: Master Data Export
            _buildDashboardCard(
              context,
              title: 'Export Master Data',
              subtitle: 'Download complete attendance spreadsheets for CHED/NSTP office',
              icon: Icons.download_for_offline,
              iconColor: Colors.green.shade700,
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Master Data Export coming soon!')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Both oversight cards land on the same screen; [initialTab] picks whether
  /// it opens grouped by class (0) or by instructor (1).
  void _openOversight(BuildContext context, {int initialTab = 0}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DirectorOversightScreen(initialTab: initialTab),
      ),
    );
  }

  Widget _buildDashboardCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
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
              child: Icon(icon, color: iconColor),
            ),
            title: Text(
              title, 
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)
            ),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
          ),
        ),
      ),
    );
  }
}