import 'package:flutter/material.dart';
import '../../models/user_model.dart';
import '../../services/notification_service.dart';
import '../../services/profile_lock_service.dart';
import '../../widgets/biometric_lock_widget.dart';
import '../../widgets/change_password_flow.dart';
import '../../widgets/lazy_tab_view.dart';
import '../../widgets/logout_helper.dart';
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

  void _showProfileView() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(Icons.account_circle, color: Colors.grey.shade600, size: 28),
              SizedBox(width: 8),
              Text(
                'Profile Details',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildProfileLockCard(),
                const Divider(height: 24),
                ListTile(
                  leading: Icon(Icons.lock_reset, color: Colors.grey.shade600),
                  title: const Text(
                    'Change Password',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Verify your identity, then set a new password',
                    style: TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    ChangePasswordFlow.show(context, widget.user);
                  },
                ),
                const Divider(height: 1),
                if (_profileLockEnabled)
                  BiometricLockWidget(child: _buildProfileDetails())
                else
                  _buildProfileDetails(),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text(
                'Close',
                style: TextStyle(
                  color: isuGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProfileDetails() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildReadOnlyTile(
          icon: Icons.person,
          label: 'Full Name',
          value: widget.user.displayName,
        ),
        const Divider(height: 1),
        _buildReadOnlyTile(
          icon: Icons.person_outline,
          label: 'First Name',
          value: widget.user.firstName ?? 'Not set',
        ),
        const Divider(height: 1),
        _buildReadOnlyTile(
          icon: Icons.person_outline,
          label: 'Middle Name',
          value: widget.user.middleName ?? 'Not set',
        ),
        const Divider(height: 1),
        _buildReadOnlyTile(
          icon: Icons.badge_outlined,
          label: 'Last Name',
          value: widget.user.lastName ?? 'Not set',
        ),
        const Divider(height: 1),
        _buildReadOnlyTile(
          icon: Icons.account_box,
          label: 'Username',
          value: widget.user.username,
        ),
        const Divider(height: 1),
        _buildReadOnlyTile(
          icon: Icons.email,
          label: 'Email Address',
          value: widget.user.email,
        ),
        const Divider(height: 1),
        _buildReadOnlyTile(
          icon: Icons.assignment_ind,
          label: 'Role',
          value: widget.user.role.toUpperCase(),
        ),
        const Divider(height: 1),
        _buildReadOnlyTile(
          icon: widget.user.isEmailVerified
              ? Icons.verified
              : Icons.mark_email_unread,
          label: 'Email Verified',
          value: widget.user.isEmailVerified ? 'Yes' : 'No',
        ),
        const Divider(height: 1),
        _buildReadOnlyTile(
          icon: Icons.calendar_today,
          label: 'Registered On',
          value: _formatJoinDate(widget.user.dateJoined),
        ),
      ],
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
        leading: Icon(icon, color: Colors.grey.shade600),
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

  String _formatJoinDate(String? iso) {
    if (iso == null || iso.trim().isEmpty) return 'Unknown';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = parsed.toLocal();
    return '${months[local.month - 1]} ${local.day}, ${local.year}';
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
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'My Profile',
            onPressed: _showProfileView,
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
