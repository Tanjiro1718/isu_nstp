import 'package:flutter/material.dart';
import '../../models/user_model.dart';
import 'admin_manage_users_screen.dart';
import '../login_screen.dart'; // Ensure this points one folder up to your login screen

class AdminDashboard extends StatelessWidget {
  final UserModel user;
  const AdminDashboard({Key? key, required this.user}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("System Administration"),
        backgroundColor: Colors.deepPurple, // Distinct color for Admin
        foregroundColor: Colors.white,
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (context) => const LoginScreen()),
                (route) => false, // Safely clears the stack to prevent black screens
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Welcome, ${user.username}!",
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "Superuser access granted. What would you like to manage?",
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 32),

            // Button 1: User Management
            _buildDashboardCard(
              context,
              title: 'Manage Users & Roles',
              subtitle: 'Add, edit, or remove students and instructors',
              icon: Icons.manage_accounts,
              iconColor: Colors.deepPurple,
              onTap: () {
                // Route to our new screen!
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const AdminManageUsersScreen()),
                );
              },
            ),
            
            const SizedBox(height: 16),
            const SizedBox(height: 16),

          ],
        ),
      ),
    );
  }

  // The exact same reusable beautiful UI card for consistency across the app
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
              backgroundColor: iconColor.withOpacity(0.15),
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