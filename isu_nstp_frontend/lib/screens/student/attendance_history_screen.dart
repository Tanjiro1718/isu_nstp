import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../config/api_config.dart';
import '../../models/user_model.dart';

/// The student's own attendance record across every class they belong to.
///
/// Shows absences as first-class rows, not just the sessions they attended -
/// a history that silently omits the misses would be worse than useless to
/// someone checking whether they are short on NSTP hours.
class AttendanceHistoryScreen extends StatefulWidget {
  final UserModel user;

  const AttendanceHistoryScreen({super.key, required this.user});

  @override
  State<AttendanceHistoryScreen> createState() =>
      _AttendanceHistoryScreenState();
}

/// Which rows the student is currently looking at.
enum _HistoryFilter { all, verified, unverified, absent }

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen> {
  static const Color isuGreen = Color(0xFF006837);
  static const Color isuDarkGreen = Color(0xFF004D25);

  bool _loading = true;
  String? _error;
  Map<String, dynamic> _summary = const {};
  List<Map<String, dynamic>> _records = const [];
  _HistoryFilter _filter = _HistoryFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http
          .get(
            Uri.parse(ApiConfig.myAttendanceHistoryUrl(widget.user.id)),
            headers: const {'ngrok-skip-browser-warning': 'true'},
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (response.statusCode != 200) {
        // The server can answer with an HTML error page, so never assume JSON.
        String message = 'Could not load your records (${response.statusCode}).';
        try {
          final body = json.decode(response.body);
          if (body is Map && body['error'] != null) {
            message = body['error'].toString();
          }
        } catch (_) {
          // Keep the status-code message.
        }
        setState(() {
          _loading = false;
          _error = message;
        });
        return;
      }

      final body = json.decode(response.body) as Map<String, dynamic>;
      setState(() {
        _loading = false;
        _summary = (body['summary'] as Map?)?.cast<String, dynamic>() ?? {};
        _records = ((body['records'] as List?) ?? [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Connection timed out. Please try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not reach the server. Check your connection.';
      });
    }
  }

  /// Rows matching the active chip.
  List<Map<String, dynamic>> get _visible {
    switch (_filter) {
      case _HistoryFilter.all:
        return _records;
      case _HistoryFilter.verified:
        return _records
            .where((r) =>
                r['attended'] == true && r['presence_status'] != 'failed')
            .toList();
      case _HistoryFilter.unverified:
        return _records
            .where((r) =>
                r['attended'] == true && r['presence_status'] == 'failed')
            .toList();
      case _HistoryFilter.absent:
        return _records.where((r) => r['attended'] != true).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text('My Attendance Record'),
        backgroundColor: isuGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: isuGreen,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: isuGreen));
    }

    if (_error != null) {
      return _buildMessage(
        icon: Icons.cloud_off,
        title: 'Could not load your records',
        body: _error!,
        showRetry: true,
      );
    }

    if (_records.isEmpty) {
      // Distinguish "no classes" from "no sessions yet" - the fix differs.
      return _buildMessage(
        icon: Icons.event_busy,
        title: 'No attendance records yet',
        body: 'Once your instructor runs an activity for a class you have '
            'joined, it will appear here.',
      );
    }

    final visible = _visible;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSummaryCard(),
        const SizedBox(height: 16),
        _buildFilterChips(),
        const SizedBox(height: 8),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                'Nothing in this category.',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ),
          )
        else
          ...visible.map(_buildRecordCard),
      ],
    );
  }

  /// Headline numbers. The rate counts only verified attendance, matching what
  /// the instructor sees, so a student is never misled into thinking a failed
  /// presence check still counted.
  Widget _buildSummaryCard() {
    final total = _summary['total_sessions'] ?? 0;
    final verified = _summary['verified'] ?? 0;
    final unverified = _summary['unverified'] ?? 0;
    final absent = _summary['absent'] ?? 0;
    final rate = (_summary['attendance_rate'] ?? 0).toString();

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.insights, color: isuGreen),
                const SizedBox(width: 8),
                const Text(
                  'Overall',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: isuDarkGreen,
                  ),
                ),
                const Spacer(),
                Text(
                  '$rate%',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                    color: _rateColor(_summary['attendance_rate']),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Verified attendance across $total activity/activities',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _statBox('Verified', verified, Colors.green),
                const SizedBox(width: 8),
                _statBox('Unverified', unverified, Colors.orange),
                const SizedBox(width: 8),
                _statBox('Absent', absent, Colors.red),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _rateColor(dynamic rate) {
    final value = rate is num ? rate.toDouble() : 0.0;
    if (value >= 85) return Colors.green.shade700;
    if (value >= 70) return Colors.orange.shade800;
    return Colors.red.shade700;
  }

  Widget _statBox(String label, Object count, MaterialColor color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.shade50,
          border: Border.all(color: color.shade200),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color.shade800,
              ),
            ),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color.shade900),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    Widget chip(String label, _HistoryFilter value) {
      final selected = _filter == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => setState(() => _filter = value),
          selectedColor: isuGreen,
          labelStyle: TextStyle(
            color: selected ? Colors.white : Colors.black87,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          chip('All', _HistoryFilter.all),
          chip('Verified', _HistoryFilter.verified),
          chip('Unverified', _HistoryFilter.unverified),
          chip('Absent', _HistoryFilter.absent),
        ],
      ),
    );
  }

  Widget _buildRecordCard(Map<String, dynamic> record) {
    final attended = record['attended'] == true;
    final failed = record['presence_status'] == 'failed';

    // Three outcomes, deliberately distinct: absent, attended-but-unproven,
    // and fully verified.
    final MaterialColor color;
    final IconData icon;
    final String statusLabel;
    if (!attended) {
      color = Colors.red;
      icon = Icons.cancel_outlined;
      statusLabel = 'Absent';
    } else if (failed) {
      color = Colors.orange;
      icon = Icons.gpp_maybe_outlined;
      statusLabel = 'Not verified';
    } else {
      color = Colors.green;
      icon = Icons.check_circle_outline;
      statusLabel = record['status']?.toString() ?? 'Present';
    }

    final totalChecks = record['total_checks'] ?? 0;
    final respondedChecks = record['responded_checks'] ?? 0;
    final note = record['note']?.toString();

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: color.shade700, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record['title']?.toString() ?? 'Activity',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: isuDarkGreen,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        record['class_name']?.toString() ?? '',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54),
                      ),
                      Text(
                        record['date_time']?.toString() ?? '',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.shade50,
                    border: Border.all(color: color.shade300),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: color.shade900,
                    ),
                  ),
                ),
              ],
            ),

            if (attended) ...[
              const Divider(height: 20),
              Row(
                children: [
                  _timeChip(
                    Icons.login,
                    'In',
                    record['time_in']?.toString() ?? '--',
                  ),
                  const SizedBox(width: 16),
                  _timeChip(
                    Icons.logout,
                    'Out',
                    // Null means they timed in and never timed out.
                    record['time_out']?.toString() ?? 'No time-out',
                  ),
                ],
              ),
              if (totalChecks is int && totalChecks > 0) ...[
                const SizedBox(height: 8),
                Text(
                  'Presence checks answered: $respondedChecks/$totalChecks',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ],

            if (note != null && note.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  note,
                  style: TextStyle(fontSize: 11, color: color.shade900),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _timeChip(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade600),
        const SizedBox(width: 4),
        Text(
          '$label: ',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String body,
    bool showRetry = false,
  }) {
    // Wrapped in a scrollable so pull-to-refresh still works when empty.
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Icon(icon, size: 56, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: isuDarkGreen,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Colors.grey),
        ),
        if (showRetry) ...[
          const SizedBox(height: 20),
          Center(
            child: FilledButton.icon(
              onPressed: _load,
              style: FilledButton.styleFrom(backgroundColor: isuGreen),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
            ),
          ),
        ],
      ],
    );
  }
}
