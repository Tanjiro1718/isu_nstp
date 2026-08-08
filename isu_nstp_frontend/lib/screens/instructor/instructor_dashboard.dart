import 'package:flutter/material.dart';
import '../../models/user_model.dart';
import '../../widgets/lazy_tab_view.dart';
import '../../widgets/logout_helper.dart';
import '../profile_screen.dart';
import 'instructor_settings_screen.dart';
import 'instructor_monitor_screen.dart';
import 'instructor_classes_screen.dart';
import 'class_attendance_records_screen.dart';
import 'instructor_excuses_screen.dart';

class InstructorDashboard extends StatefulWidget {
  final UserModel user;
  const InstructorDashboard({super.key, required this.user});

  @override
  State<InstructorDashboard> createState() => _InstructorDashboardState();
}

class _InstructorDashboardState extends State<InstructorDashboard> {
  int _currentIndex = 0;

  /// Shown in the AppBar so the bar still says where you are once the cards
  /// that used to carry those labels are gone.
  static const _titles = [
    'Create Attendance Session',
    'Monitor Headcounts',
    'Class Attendance Record',
    'My Classes',
    'Excuse Letters',
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
      // Each tab is the same screen the old card used to push, minus its own
      // AppBar so this one stays the only bar on screen.
      body: LazyTabView(
        currentIndex: _currentIndex,
        builders: [
          (_) => InstructorSettingsScreen(user: widget.user, embedded: true),
          (_) =>
              InstructorMonitorScreen(instructor: widget.user, embedded: true),
          (_) =>
              ClassAttendanceRecordsScreen(user: widget.user, embedded: true),
          (_) => InstructorClassesScreen(user: widget.user, embedded: true),
          (_) => InstructorExcusesScreen(user: widget.user, embedded: true),
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
            icon: Icon(Icons.add_location_alt_outlined),
            activeIcon: Icon(Icons.add_location_alt),
            label: 'Session',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.people_outline),
            activeIcon: Icon(Icons.people),
            label: 'Monitor',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_today_outlined),
            activeIcon: Icon(Icons.calendar_today),
            label: 'Records',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.school_outlined),
            activeIcon: Icon(Icons.school),
            label: 'Classes',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.drafts_outlined),
            activeIcon: Icon(Icons.drafts),
            label: 'Excuses',
          ),
        ],
      ),
    );
  }
}
