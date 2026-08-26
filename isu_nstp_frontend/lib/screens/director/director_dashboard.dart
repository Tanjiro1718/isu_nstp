import 'package:flutter/material.dart';
import '../../models/user_model.dart';
import '../../widgets/lazy_tab_view.dart';
import '../../widgets/logout_helper.dart';
import '../profile_screen.dart';
import 'director_oversight_screen.dart';
import 'director_attendance_records_screen.dart';

class DirectorDashboard extends StatefulWidget {
  final UserModel user;

  const DirectorDashboard({super.key, required this.user});

  @override
  State<DirectorDashboard> createState() => _DirectorDashboardState();
}

class _DirectorDashboardState extends State<DirectorDashboard> {
  int _currentIndex = 0;

  static const _titles = [
    'Campus Analytics',
    'Instructor Compliance',
    'Attendance Records',
    'Export Master Data',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Text(
          _titles[_currentIndex],
          style: const TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.w600,
            fontSize: 20,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 1,
        iconTheme: const IconThemeData(color: Colors.black87),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'My Profile',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ProfileScreen(user: widget.user),
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
      // The first two tabs are the same oversight screen opened on its "By
      // Class" and "By Instructor" views, exactly as the old cards did.
      body: LazyTabView(
        currentIndex: _currentIndex,
        builders: [
          (_) => const DirectorOversightScreen(initialTab: 0, embedded: true),
          (_) => const DirectorOversightScreen(initialTab: 1, embedded: true),
          (_) => DirectorAttendanceRecordsScreen(user: widget.user),
          (_) => _ExportMasterDataTab(user: widget.user),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.white,
        selectedItemColor: Colors.black87,
        unselectedItemColor: Colors.grey[500],
        selectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
        unselectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w500,
          fontSize: 12,
        ),
        elevation: 8,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.pie_chart_outline),
            activeIcon: Icon(Icons.pie_chart),
            label: 'Analytics',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.assignment_ind_outlined),
            activeIcon: Icon(Icons.assignment_ind),
            label: 'Instructors',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long_outlined),
            activeIcon: Icon(Icons.receipt_long),
            label: 'Records',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.download_outlined),
            activeIcon: Icon(Icons.download),
            label: 'Export',
          ),
        ],
      ),
    );
  }
}

/// Placeholder tab for the CHED/NSTP office spreadsheet export. Keeps the
/// greeting that used to live at the top of the dashboard.
class _ExportMasterDataTab extends StatelessWidget {
  final UserModel user;

  const _ExportMasterDataTab({required this.user});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Welcome, Director ${user.username}!',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Oversee campus analytics, instructor compliance, and master records.',
          style: TextStyle(fontSize: 14, color: Colors.grey),
        ),
        const SizedBox(height: 28),
        Card(
          elevation: 3,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor:
                          Colors.green.shade700.withValues(alpha: 0.15),
                      child: Icon(
                        Icons.download_for_offline,
                        color: Colors.green.shade700,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Export Master Data',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Download complete attendance spreadsheets for the CHED/NSTP '
                  'office.',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Master Data Export coming soon!'),
                        ),
                      );
                    },
                    icon: const Icon(Icons.download),
                    label: const Text('Download spreadsheet'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
