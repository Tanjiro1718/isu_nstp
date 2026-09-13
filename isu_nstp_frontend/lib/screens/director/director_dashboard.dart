import 'package:flutter/material.dart';
import '../../models/user_model.dart';
import '../../widgets/lazy_tab_view.dart';
import '../../widgets/logout_helper.dart';
import '../profile_screen.dart';
import 'director_oversight_screen.dart';
import 'director_attendance_records_screen.dart';
import 'director_export_screen.dart';

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
      // The first tab opens the oversight screen on its Overview landing view.
      body: LazyTabView(
        currentIndex: _currentIndex,
        builders: [
          (_) => const DirectorOversightScreen(initialTab: 0, embedded: true),
          (_) => DirectorAttendanceRecordsScreen(user: widget.user),
          (_) => const DirectorExportScreen(),
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

