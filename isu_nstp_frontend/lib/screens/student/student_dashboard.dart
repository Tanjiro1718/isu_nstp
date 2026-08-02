import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../config/api_config.dart';
import '../../models/user_model.dart';
import '../../services/class_service.dart';
import '../../services/presence_service.dart';
import '../../services/profile_lock_service.dart';
import '../../widgets/biometric_lock_widget.dart';
import '../login_screen.dart';
import '../profile_screen.dart';
import 'student_checkin_screen.dart';

class StudentDashboard extends StatefulWidget {
  final UserModel user;
  const StudentDashboard({super.key, required this.user});

  @override
  State<StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<StudentDashboard> {
  bool _isOpeningCheckIn = false;
  late UserModel _currentUser;

  // Classes this student has joined, loaded from the API.
  List<Map<String, dynamic>> _myClasses = [];
  bool _isLoadingClasses = true;
  String? _classesError;

  // --- Live presence verification state ---
  PresenceStatus? _presence;
  Timer? _presencePoller;
  bool _isRespondingToCheck = false;
  bool _isCheckingOut = false;

  /// Owned by this State rather than by the dialog: disposing it as soon as
  /// showDialog() returns kills it while the dialog is still animating out,
  /// and the TextField then rebuilds against a disposed controller.
  final TextEditingController _joinCodeController = TextEditingController();

  // --- Face Unlock protection for profile details ---
  bool _profileLockEnabled = false;
  bool _biometricAvailable = false;

  // --- ISU Theme Colors ---
  static const Color isuGreen = Color(0xFF006837);

  @override
  void initState() {
    super.initState();
    _currentUser = widget.user;
    _loadMyClasses();
    _startPresencePolling();
    _loadProfileLockState();
  }

  /// Reads the saved preference and checks whether this device can actually
  /// do a biometric check, so the settings row can explain itself accurately.
  Future<void> _loadProfileLockState() async {
    final available = await ProfileLockService.isBiometricAvailable();
    final enabled = await ProfileLockService.isLockEnabled(_currentUser.id);
    if (!mounted) return;
    setState(() {
      _biometricAvailable = available;
      _profileLockEnabled = enabled;
    });
  }

  /// Turning the lock ON requires passing the check first - that proves the
  /// student can actually get back in before we start hiding their data.
  Future<void> _toggleProfileLock(bool enable) async {
    if (enable) {
      final result = await ProfileLockService.authenticate(
        reason: 'Verify your identity to turn on profile protection',
      );
      if (!mounted) return;

      if (result == LockResult.unavailable) {
        _showSnackBar(
          'No face or fingerprint is set up on this device. Add one in your '
          'device settings first.',
          Colors.orange,
        );
        return;
      }
      if (result == LockResult.failed) {
        _showSnackBar('Verification failed. Profile lock not enabled.', Colors.red);
        return;
      }
    }

    await ProfileLockService.setLockEnabled(_currentUser.id, enable);
    if (!mounted) return;
    setState(() => _profileLockEnabled = enable);
    _showSnackBar(
      enable
          ? 'Profile details are now protected by Face Unlock.'
          : 'Profile protection turned off.',
      enable ? isuGreen : Colors.grey.shade700,
    );
  }

  /// Polls for presence checks so a student with the app open still sees the
  /// prompt even if the push notification is delayed or was swiped away.
  void _startPresencePolling() {
    _refreshPresence();
    _presencePoller = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _refreshPresence(),
    );
  }

  Future<void> _refreshPresence() async {
    final status = await PresenceService.fetchStatus(_currentUser.id);
    // A null result means the network hiccuped; keep showing the last state.
    if (status != null && mounted) {
      setState(() => _presence = status);
    }
  }

  Future<void> _respondToPresenceCheck() async {
    final checkId = _presence?.pendingCheckId;
    if (checkId == null) return;

    setState(() => _isRespondingToCheck = true);
    final result = await PresenceService.respondToCheck(
      checkId: checkId,
      studentUserId: _currentUser.id,
    );

    if (!mounted) return;
    setState(() => _isRespondingToCheck = false);
    _showSnackBar(result.message, result.success ? Colors.green : Colors.red);
    await _refreshPresence();
  }

  Future<void> _submitCheckOut() async {
    final recordId = _presence?.recordId;
    if (recordId == null) return;

    setState(() => _isCheckingOut = true);
    final result = await PresenceService.checkOut(
      recordId: recordId,
      studentUserId: _currentUser.id,
    );

    if (!mounted) return;
    setState(() => _isCheckingOut = false);
    _showSnackBar(result.message, result.success ? Colors.green : Colors.red);
    await _refreshPresence();
  }

  @override
  void dispose() {
    _presencePoller?.cancel();
    _joinCodeController.dispose();
    super.dispose();
  }

  Future<void> _loadMyClasses() async {
    setState(() {
      _isLoadingClasses = true;
      _classesError = null;
    });

    try {
      final classes = await ClassService.fetchStudentClasses(_currentUser.id);
      if (!mounted) return;
      setState(() {
        _myClasses = classes;
        _isLoadingClasses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _classesError = e.toString();
        _isLoadingClasses = false;
      });
    }
  }

  /// Opens the check-in screen for the newest session. When [classId] is given
  /// the session is limited to that class, otherwise any joined class counts.
  Future<void> _openCurrentSessionCheckIn({int? classId}) async {
    setState(() => _isOpeningCheckIn = true);

    try {
      final response = await http.get(
        Uri.parse(
          ApiConfig.currentSessionForStudentUrl(
            _currentUser.id,
            classId: classId,
          ),
        ),
        headers: const {'ngrok-skip-browser-warning': 'true'},
      );

      if (!mounted) return;
      setState(() => _isOpeningCheckIn = false);

      if (response.statusCode != 200) {
        String message =
            'No active attendance session found. Ask your instructor to start one.';
        try {
          final body = json.decode(response.body);
          if (body is Map && body['message'] != null) {
            message = body['message'].toString();
          }
        } catch (_) {
          // Non-JSON body, keep the default message.
        }
        _showSnackBar(message, Colors.red);
        return;
      }

      final data = json.decode(response.body);

      // Work out when the photo window shuts so the screen can count down.
      DateTime? photoDeadline;
      final startedAt = DateTime.tryParse('${data['date_time']}');
      final windowMinutes = data['photo_window_minutes'];
      if (startedAt != null && windowMinutes != null) {
        final minutes = windowMinutes is int
            ? windowMinutes
            : int.tryParse('$windowMinutes');
        if (minutes != null) {
          photoDeadline = startedAt.toLocal().add(Duration(minutes: minutes));
        }
      }

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => StudentCheckInScreen(
            user: widget.user,
            sessionId: data['id'],
            targetLat: double.parse(data['target_latitude'].toString()),
            targetLng: double.parse(data['target_longitude'].toString()),
            allowedRadiusMeters: data['radius_meters'],
            photoDeadline: photoDeadline,
          ),
        ),
      );

      // Coming back from a successful time-in, the presence banner should
      // appear immediately rather than on the next poll.
      await _refreshPresence();
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

  Future<void> _showJoinClassDialog() async {
    _joinCodeController.clear();
    bool isJoining = false;

    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.group_add, color: isuGreen, size: 28),
              SizedBox(width: 8),
              Text('Join a Class', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Ask your instructor for the class code, then enter it below.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _joinCodeController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Class Code',
                  hintText: 'e.g. ABC123',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.vpn_key),
                ),
                enabled: !isJoining,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isJoining ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: isJoining
                  ? null
                  : () async {
                      final code = _joinCodeController.text.trim();
                      if (code.isEmpty) {
                        _showSnackBar('Please enter a class code', Colors.red);
                        return;
                      }

                      setState(() => isJoining = true);

                      String? successMessage;
                      String? errorMessage;

                      try {
                        final response = await http.post(
                          Uri.parse(ApiConfig.joinClassByCodeUrl),
                          headers: {'Content-Type': 'application/json'},
                          body: jsonEncode({
                            'join_code': code,
                            'student_id': _currentUser.id,
                          }),
                        );

                        // The server can answer with an HTML error page, so never
                        // assume the body is JSON.
                        Map<String, dynamic> body = {};
                        try {
                          final decoded = jsonDecode(response.body);
                          if (decoded is Map<String, dynamic>) body = decoded;
                        } catch (_) {
                          // Leave body empty and fall back to a generic message.
                        }

                        if (response.statusCode == 200 ||
                            response.statusCode == 201) {
                          successMessage =
                              body['message']?.toString() ?? 'Joined class!';
                        } else {
                          errorMessage =
                              body['error']?.toString() ??
                              body['detail']?.toString() ??
                              'Could not join class (${response.statusCode})';
                        }
                      } catch (e) {
                        errorMessage = 'Network error. Check your connection.';
                      }

                      if (!dialogContext.mounted) return;

                      if (successMessage != null) {
                        // Close first, then report - touching setState after the
                        // dialog is popped throws.
                        Navigator.pop(dialogContext);
                        _showSnackBar(successMessage, Colors.green);
                        _loadMyClasses(); // Reflect the new class right away.
                        return;
                      }

                      setState(() => isJoining = false);
                      _showSnackBar(errorMessage!, Colors.red);
                    },

              style: FilledButton.styleFrom(backgroundColor: isuGreen),
              child: isJoining
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Join'),
            ),
          ],
        ),
      ),
    );
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
      body: RefreshIndicator(
        onRefresh: _loadMyClasses,
        color: isuGreen,
        child: Padding(
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
            const SizedBox(height: 24),

            // Presence verification takes priority over everything else.
            if (_presence?.hasRecord == true) ...[
              _buildPresenceSection(),
              const SizedBox(height: 24),
            ],

            _buildMyClassesSection(),
            const SizedBox(height: 24),
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
              title: 'Join a Class',
              subtitle: 'Enter a class code to join',
              icon: Icons.group_add,
              iconColor: Colors.blue,
              onTap: () async {
                await _showJoinClassDialog();
              },
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
            const SizedBox(height: 16),
            _buildProfileLockCard(),
          ],
        ),
        ),
      ),
    );
  }

  /// The live presence panel: an urgent prompt when a random check is waiting,
  /// otherwise the verification state plus the check-out button.
  Widget _buildPresenceSection() {
    final presence = _presence!;

    // 1. A check is waiting right now - this is the urgent case.
    if (presence.hasPendingCheck) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          border: Border.all(color: Colors.orange.shade400, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notifications_active, color: Colors.orange.shade800),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Are you still here?',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                      color: Colors.orange.shade900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Confirm your presence for "${presence.sessionTitle}". '
              'You must be at the activity location.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isRespondingToCheck ? null : _respondToPresenceCheck,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.orange.shade800,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: _isRespondingToCheck
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: Text(
                  _isRespondingToCheck
                      ? 'Confirming...'
                      : "Yes, I'm still here",
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 2. Verification failed - check-out is gone.
    if (presence.isFailed) {
      return _buildPresenceInfoCard(
        color: Colors.red,
        icon: Icons.gpp_bad,
        title: 'Attendance verification failed',
        body:
            'You missed ${presence.missedChecks} presence checks, so you can no '
            'longer submit a time-out photo for this activity. Please contact '
            'your instructor.',
      );
    }

    // 3. Already checked out - nothing left to do.
    if (presence.checkedOut) {
      return _buildPresenceInfoCard(
        color: Colors.green,
        icon: Icons.task_alt,
        title: 'Attendance complete',
        body:
            'You timed in and out for "${presence.sessionTitle}". '
            'Responded to ${presence.respondedChecks} of '
            '${presence.totalChecks} presence check(s).',
      );
    }

    // 4. Activity in progress: show a warning if they already missed one.
    final warned = presence.isWarned;
    // Timed in and verified, but the instructor has not released time-out yet.
    final onStandby = !presence.checkOutOpen;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: warned ? Colors.amber.shade50 : Colors.green.shade50,
        border: Border.all(
          color: warned ? Colors.amber.shade600 : Colors.green.shade300,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                warned ? Icons.warning_amber_rounded : Icons.how_to_reg,
                color: warned ? Colors.amber.shade900 : Colors.green.shade800,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  warned ? 'Warning: check missed' : 'Timed in',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color:
                        warned ? Colors.amber.shade900 : Colors.green.shade900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            warned
                ? 'You did not respond to a presence check. Respond to the next '
                      'one or you will lose your time-out for this activity.'
                : 'You are timed in for "${presence.sessionTitle}". Stay on site '
                      'and watch for random presence checks.',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            'Presence checks answered: ${presence.respondedChecks}/${presence.totalChecks}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),

          if (onStandby) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                border: Border.all(color: Colors.orange.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.hourglass_top,
                    size: 18,
                    color: Colors.orange.shade900,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'On standby. Your instructor has not opened time-out yet. '
                      'You will be notified the moment it opens.',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.orange.shade900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              // Disabled while on standby so students cannot leave early.
              onPressed:
                  (_isCheckingOut || onStandby) ? null : _submitCheckOut,
              icon: _isCheckingOut
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(onStandby ? Icons.lock_clock : Icons.logout),
              label: Text(
                _isCheckingOut
                    ? 'Checking out...'
                    : onStandby
                        ? 'Time Out locked'
                        : 'Time Out',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresenceInfoCard({
    required MaterialColor color,
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.shade50,
        border: Border.all(color: color.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: color.shade900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(body, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  /// Shows every class the student has joined. Tapping one jumps straight to
  /// that class's check-in.
  Widget _buildMyClassesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.school, color: isuGreen, size: 20),
            const SizedBox(width: 8),
            const Text(
              'My Classes',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            if (!_isLoadingClasses)
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: 'Refresh classes',
                onPressed: _loadMyClasses,
              ),
          ],
        ),
        const SizedBox(height: 8),

        if (_isLoadingClasses)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_classesError != null)
          _buildClassesPlaceholder(
            icon: Icons.cloud_off,
            title: 'Could not load your classes',
            subtitle: _classesError!,
          )
        else if (_myClasses.isEmpty)
          _buildClassesPlaceholder(
            icon: Icons.school_outlined,
            title: 'You have not joined any class yet',
            subtitle:
                'Tap "Join a Class" below and enter the code from your instructor.',
          )
        else
          ..._myClasses.map(_buildClassTile),
      ],
    );
  }

  Widget _buildClassesPlaceholder({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, size: 36, color: Colors.grey),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildClassTile(Map<String, dynamic> classData) {
    final name = classData['name']?.toString() ?? 'Unnamed class';
    final component = classData['component']?.toString() ?? '';
    final sectionCode = classData['section_code']?.toString() ?? '';
    final instructor = classData['instructor_name']?.toString() ?? '';
    final status = (classData['enrollment_status'] ?? 'active').toString();
    final isPending = status == 'pending';

    final subtitleParts = [
      if (component.isNotEmpty) component,
      if (sectionCode.isNotEmpty) sectionCode,
    ].join(' - ');

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: isPending
              ? Colors.orange.withValues(alpha: 0.15)
              : isuGreen.withValues(alpha: 0.15),
          child: Icon(
            isPending ? Icons.hourglass_top : Icons.class_,
            color: isPending ? Colors.orange : isuGreen,
          ),
        ),
        title: Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitleParts.isNotEmpty)
              Text(subtitleParts, style: const TextStyle(fontSize: 13)),
            if (instructor.isNotEmpty)
              Text(
                'Instructor: $instructor',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            if (isPending)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Waiting for instructor approval',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        trailing: isPending
            ? null
            : const Icon(Icons.login, color: isuGreen, size: 20),
        // Pending students cannot check in yet, so the tile is inert for them.
        onTap: isPending || _isOpeningCheckIn
            ? null
            : () => _openCurrentSessionCheckIn(
                classId: classData['id'] is int
                    ? classData['id'] as int
                    : int.tryParse('${classData['id']}'),
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
            // With protection on the details stay hidden until Face Unlock
            // passes. Gating here rather than on the button means the lock
            // re-arms every time the dialog is reopened.
            child: _profileLockEnabled
                ? BiometricLockWidget(child: _buildProfileDetails())
                : _buildProfileDetails(),
          ),
          actions: [
            // Security lives on the shared profile screen, so send them there.
            TextButton.icon(
              onPressed: () {
                Navigator.pop(dialogContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ProfileScreen(user: _currentUser),
                  ),
                );
              },
              icon: const Icon(Icons.lock_reset, size: 18, color: isuGreen),
              label: const Text(
                'Change Password',
                style: TextStyle(color: isuGreen, fontWeight: FontWeight.bold),
              ),
            ),
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

  /// The personal details themselves, extracted so they can be rendered either
  /// directly or behind the biometric gate.
  Widget _buildProfileDetails() {
    return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildReadOnlyTile(
                  icon: Icons.person,
                  label: 'Full Name',
                  value: _currentUser.displayName,
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.person_outline,
                  label: 'First Name',
                  value: _currentUser.firstName ?? 'Not set',
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.person_outline,
                  label: 'Middle Name',
                  value: _currentUser.middleName ?? 'Not set',
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.badge_outlined,
                  label: 'Last Name',
                  value: _currentUser.lastName ?? 'Not set',
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.account_box,
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
                  icon: Icons.email,
                  label: 'Email Address',
                  value: _currentUser.email,
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.school,
                  label: 'Course & Section',
                  value: _currentUser.courseAndSection ?? 'Not assigned',
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.workspace_premium,
                  label: 'NSTP Component',
                  value: _currentUser.component ?? 'Not assigned',
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.class_,
                  label: 'Section Code',
                  value: _currentUser.sectionCode ?? 'Not assigned',
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.assignment_ind,
                  label: 'Role',
                  value: _currentUser.role.toUpperCase(),
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: _currentUser.isEmailVerified
                      ? Icons.verified
                      : Icons.mark_email_unread,
                  label: 'Email Verified',
                  value: _currentUser.isEmailVerified ? 'Yes' : 'No',
                ),
                const Divider(height: 1),
                _buildReadOnlyTile(
                  icon: Icons.calendar_today,
                  label: 'Registered On',
                  value: _formatJoinDate(_currentUser.dateJoined),
                ),
              ],
    );
  }

  /// Lets the student put their personal details behind the device's own face
  /// or fingerprint check. Nothing biometric is uploaded or stored by the app -
  /// the match happens inside the OS, and only this on/off flag is saved.
  Widget _buildProfileLockCard() {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: SwitchListTile(
          value: _profileLockEnabled,
          onChanged: _biometricAvailable ? _toggleProfileLock : null,
          activeThumbColor: isuGreen,
          secondary: CircleAvatar(
            backgroundColor: isuGreen.withValues(alpha: 0.15),
            child: const Icon(Icons.face_retouching_natural, color: isuGreen),
          ),
          title: const Text(
            'Protect My Profile',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          subtitle: Text(
            _biometricAvailable
                ? 'Require Face Unlock before showing your profile details'
                : 'Set up face or fingerprint unlock on this device to use this',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }

  /// Turns the ISO timestamp from the API into something readable.
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