import 'package:flutter/material.dart';
import '../../models/user_model.dart';
import '../../services/instructor_sessions_service.dart';
import 'class_attendance_records_screen.dart';

/// "My Sessions" - every attendance session the instructor created, newest
/// first, with a quick view of how many students timed in.
///
/// Tapping a session opens the Class Attendance Record for that class and day,
/// so the schedule doubles as a shortcut into the detail behind it.
class InstructorSessionsScreen extends StatefulWidget {
  final UserModel user;

  const InstructorSessionsScreen({super.key, required this.user});

  @override
  State<InstructorSessionsScreen> createState() =>
      _InstructorSessionsScreenState();
}

enum _SessionFilter { all, upcoming, past }

class _InstructorSessionsScreenState extends State<InstructorSessionsScreen> {
  late Future<List<InstructorSession>> _future;
  _SessionFilter _filter = _SessionFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = InstructorSessionsService.fetch(widget.user.id);
  }

  Future<void> _refresh() async {
    setState(_load);
    // Errors are rendered by the FutureBuilder; swallow them here.
    await _future.catchError((_) => <InstructorSession>[]);
  }

  List<InstructorSession> _visible(List<InstructorSession> sessions) {
    switch (_filter) {
      case _SessionFilter.all:
        return sessions;
      case _SessionFilter.upcoming:
        return sessions.where((s) => s.isUpcoming).toList();
      case _SessionFilter.past:
        return sessions.where((s) => !s.isUpcoming).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text('My Sessions'),
        backgroundColor: Colors.blue.shade800,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<InstructorSession>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return _Message(
                icon: Icons.cloud_off,
                text: snapshot.error.toString(),
                onRetry: () => setState(_load),
              );
            }

            final sessions = snapshot.data ?? [];
            if (sessions.isEmpty) {
              return const _Message(
                icon: Icons.event_busy,
                text: 'You have not created any sessions yet.\n'
                    'Start one from the Session tab and it will show up here.',
              );
            }

            final visible = _visible(sessions);

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildFilters(),
                const SizedBox(height: 12),
                if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Text(
                        'Nothing in this category.',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ),
                  )
                else
                  ...visible.map(
                    (session) => _SessionCard(
                      session: session,
                      onTap: () => _openRecords(session),
                      onCancel: () => _cancelSession(session),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildFilters() {
    Widget chip(String label, _SessionFilter value) {
      final selected = _filter == value;
      return ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _filter = value),
        selectedColor: Colors.blue.shade800,
        labelStyle: TextStyle(
          color: selected ? Colors.white : Colors.black87,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return Wrap(
      spacing: 8,
      children: [
        chip('All', _SessionFilter.all),
        chip('Upcoming', _SessionFilter.upcoming),
        chip('Past', _SessionFilter.past),
      ],
    );
  }

  void _openRecords(InstructorSession session) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ClassAttendanceRecordsScreen(
          user: widget.user,
          initialClassId: session.classId,
          initialDate: session.localDate,
        ),
      ),
    );
  }

  Future<void> _cancelSession(InstructorSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this session?'),
        content: Text(
          '"${session.title}" will be called off. Any attendance already '
          'recorded stays on file, but students will no longer see it and it '
          'will not be counted in reports.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cancel session'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await InstructorSessionsService.cancel(session.sessionId, widget.user.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session cancelled.')),
      );
      setState(_load);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

class _SessionCard extends StatelessWidget {
  final InstructorSession session;
  final VoidCallback onTap;
  final VoidCallback? onCancel;

  const _SessionCard({
    required this.session,
    required this.onTap,
    this.onCancel,
  });

  (Color, IconData) get _statusStyle {
    switch (session.status) {
      case 'Upcoming':
        return (Colors.blue, Icons.schedule);
      case 'Ongoing':
        return (Colors.green, Icons.play_circle_outline);
      case 'Cancelled':
        return (Colors.grey, Icons.event_busy);
      default:
        return (Colors.grey, Icons.check_circle_outline);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _statusStyle;
    final progress =
        session.expected > 0 ? session.checkedIn / session.expected : 0.0;

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        onTap: session.isCancelled ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: session.isCancelled ? Colors.grey : null,
                            decoration: session.isCancelled
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          session.className,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      session.status,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ),
                  if (session.canCancel && onCancel != null)
                    PopupMenuButton<String>(
                      tooltip: 'Session actions',
                      icon: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: Colors.grey.shade600,
                      ),
                      onSelected: (_) => onCancel!(),
                      itemBuilder: (context) => const [
                        PopupMenuItem<String>(
                          value: 'cancel',
                          child: Row(
                            children: [
                              Icon(Icons.event_busy, size: 18, color: Colors.red),
                              SizedBox(width: 8),
                              Text('Cancel session'),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.event, size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 6),
                  Text(
                    session.dateTime,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.how_to_reg_outlined,
                    size: 14,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${session.checkedIn}/${session.expected} timed in',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${session.attendanceRate.toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 5,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback? onRetry;

  const _Message({required this.icon, required this.text, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Icon(icon, size: 64, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade700, height: 1.4),
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 20),
          Center(
            child: FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ),
        ],
      ],
    );
  }
}
