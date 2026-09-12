import 'package:flutter/material.dart';
import '../../models/user_model.dart';
import '../../services/notification_service.dart';
import '../../services/profile_lock_service.dart';
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
  /// Fires on every tab tap so kept-alive tabs (e.g. My Classes) can refresh
  /// their data when they become visible again.
  final ValueNotifier<int> _selectedTab = ValueNotifier<int>(0);

  /// Shown in the AppBar so the bar still says where you are once the cards
  /// that used to carry those labels are gone.
  static const _titles = [
    'Create Attendance Session',
    'Monitor Headcounts',
    'Class Attendance Record',
    'My Classes',
    'Excuse Letters',
  ];

  // --- Device-lock protection for profile details ---
  bool _profileLockEnabled = false;
  bool _biometricAvailable = false;

  static const Color isuGreen = Color(0xFF006837);

  @override
  void initState() {
    super.initState();
    _loadProfileLockState();
    // Tapping a "student checked in" push jumps straight to the Monitor tab.
    instructorNavRequests.addListener(_onNavRequest);
    _onNavRequest();
  }

  /// Reacts to instructor navigation intents (e.g. a check-in push tap) by
  /// switching tabs, then swallows the request so it cannot fire again.
  void _onNavRequest() {
    final request = instructorNavRequests.value;
    if (request == null || request.tabIndex == _currentIndex) return;
    instructorNavRequests.value = null;
    if (!mounted) return;
    _selectedTab.value = request.tabIndex;
    setState(() => _currentIndex = request.tabIndex);
  }

  @override
  void dispose() {
    instructorNavRequests.removeListener(_onNavRequest);
    _selectedTab.dispose();
    super.dispose();
  }

  Future<void> _loadProfileLockState() async {
    final available = await ProfileLockService.isBiometricAvailable();
    final enabled = await ProfileLockService.isLockEnabled(widget.user.id);
    if (!mounted) return;
    setState(() {
      _biometricAvailable = available;
      _profileLockEnabled = enabled;
    });
  }

  Future<void> _toggleProfileLock(bool enable) async {
    final result = await ProfileLockService.authenticate(
      reason: enable
          ? 'Verify your identity to turn on profile protection'
          : 'Verify your identity to turn off profile protection',
    );
    if (!mounted) return;

    if (result == LockResult.failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enable
                ? 'Verification failed. Profile lock not enabled.'
                : 'Verification failed. Profile protection stays on.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (result == LockResult.lockedOut) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Too many attempts. Unlock your device the usual way, then try again.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (enable) {
      if (result == LockResult.notEnrolled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No screen lock is set up on this device. Add a face, fingerprint, '
              'or PIN in your device settings first.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      if (result == LockResult.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open the verification prompt on this device.',
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    await ProfileLockService.setLockEnabled(widget.user.id, enable);
    if (!mounted) return;
    setState(() => _profileLockEnabled = enable);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enable
              ? 'Profile details are now protected by your device lock.'
              : 'Profile protection turned off.',
        ),
        backgroundColor: enable ? isuGreen : Colors.grey.shade700,
      ),
    );
  }

  /// Opens the full-profile screen (shared with admin/director), which keeps
  /// the profile-lock protection in force: when enabled, the device unlock is
  /// requested before the screen is shown.
  Future<void> _openProfileScreen() async {
    if (_profileLockEnabled) {
      final result = await ProfileLockService.authenticate(
        reason: 'Verify your identity to view your profile details',
      );
      if (!mounted) return;
      // Match BiometricLockWidget: a real failure keeps the details closed,
      // while not-enrolled/error still let the instructor through.
      if (result == LockResult.failed || result == LockResult.lockedOut) return;
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileScreen(user: widget.user),
      ),
    );
  }

  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 16),
                _buildSettingsCard(
                  icon: Icons.account_circle,
                  iconColor: Colors.grey.shade600,
                  title: 'Profile Details',
                  subtitle: 'View and edit your name, position, and contact details',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openProfileScreen();
                  },
                ),
                const SizedBox(height: 12),
                _buildProfileLockCard(),
                const SizedBox(height: 12),
                _buildSettingsCard(
                  icon: Icons.logout,
                  iconColor: Colors.grey.shade600,
                  title: 'Log Out',
                  subtitle: 'Sign out of your account',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    LogoutHelper.confirmAndLogout(context);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingsCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 3,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: iconColor.withValues(alpha: 0.15),
            child: Icon(icon, color: iconColor),
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
    );
  }

  Widget _buildProfileLockCard() {
    return Card(
      elevation: 0,
      color: Colors.grey.shade50,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.0),
        child: SwitchListTile(
          value: _profileLockEnabled,
          onChanged: _biometricAvailable ? _toggleProfileLock : null,
          activeThumbColor: isuGreen,
          secondary: CircleAvatar(
            backgroundColor: isuGreen.withValues(alpha: 0.15),
            child: Icon(
              Icons.face_retouching_natural,
              color: Colors.grey.shade600,
            ),
          ),
          title: const Text(
            'Protect My Profile',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Text(
            !_biometricAvailable
                ? 'Set up a screen lock on this device to use this'
                : _profileLockEnabled
                    ? 'Protected. Verification required to turn off.'
                    : 'Require device unlock before showing details',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
  }

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
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _showSettingsSheet,
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
          (_) => InstructorClassesScreen(
                user: widget.user,
                embedded: true,
                tabSwitch: _selectedTab,
                tabIndex: 3,
              ),
          (_) => InstructorExcusesScreen(user: widget.user, embedded: true),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() => _currentIndex = index);
          _selectedTab.value = index;
        },
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
