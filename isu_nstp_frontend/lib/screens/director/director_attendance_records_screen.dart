import 'package:flutter/material.dart';

import '../../models/user_model.dart';
import '../../services/director_service.dart';

/// Director's day view of campus attendance.
///
/// One row per student for the chosen day, rolled up across the activities
/// they were expected at. The director filters by program and (optionally) a
/// single class, then expands a student to see each activity's detail.
class DirectorAttendanceRecordsScreen extends StatefulWidget {
  final UserModel user;
  final bool embedded;

  const DirectorAttendanceRecordsScreen({
    super.key,
    required this.user,
    this.embedded = true,
  });

  @override
  State<DirectorAttendanceRecordsScreen> createState() =>
      _DirectorAttendanceRecordsScreenState();
}

class _DirectorAttendanceRecordsScreenState
    extends State<DirectorAttendanceRecordsScreen> {
  static const Color isuGreen = Color(0xFF006837);
  static const List<String> _programs = ['All', 'CWTS', 'LTS', 'ROTC'];

  List<ClassOversight> _classes = [];

  String _program = 'All';
  int? _classId;
  late DateTime _date;

  DailyRecords? _data;
  bool _loading = true;
  bool _loadingRecords = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _date = DateTime.now();
    _loadClasses();
  }

  Future<void> _loadClasses() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await DirectorService.fetchOverview();
      if (!mounted) return;
      setState(() {
        _classes = overview.classes;
        _loading = false;
      });
      await _loadRecords();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _loadRecords() async {
    setState(() {
      _loadingRecords = true;
      _error = null;
    });
    try {
      final data = await DirectorService.fetchDailyRecords(
        component: _program == 'All' ? null : _program,
        classId: _classId,
        date: _fmt(_date),
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loadingRecords = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loadingRecords = false;
      });
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _pretty(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _date = picked);
      _loadRecords();
    }
  }

  // ---------------------------------------------------------------
  // Presentation helpers
  // ---------------------------------------------------------------

  static Color _statusColor(String status) {
    switch (status) {
      case 'Present':
        return Colors.green;
      case 'Partial':
        return Colors.amber.shade800;
      case 'Absent':
        return Colors.red;
      case 'Excused':
        return Colors.blueGrey;
      default:
        return Colors.grey;
    }
  }

  static IconData _statusIcon(String status) {
    switch (status) {
      case 'Present':
        return Icons.check_circle;
      case 'Partial':
        return Icons.error_outline;
      case 'Absent':
        return Icons.cancel;
      case 'Excused':
        return Icons.event_available;
      default:
        return Icons.help_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: isuGreen));
    }

    return Column(
      children: [
        _buildFilters(),
        if (_data != null) _buildSummary(_data!.summary),
        Expanded(
          child: _loadingRecords
              ? const Center(child: CircularProgressIndicator(color: isuGreen))
              : _error != null
                  ? _buildErrorState()
                  : _buildRecordsList(),
        ),
      ],
    );
  }

  Widget _buildFilters() {
    return Card(
      margin: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Select Date',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _pickDate,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today,
                        size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _pretty(_date),
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    if (!_isToday(_date))
                      TextButton(
                        onPressed: () {
                          setState(() => _date = DateTime.now());
                          _loadRecords();
                        },
                        child: const Text('Today'),
                      )
                    else
                      Icon(Icons.arrow_drop_down,
                          color: Colors.grey.shade600),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text('Program',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _programs.map(_programChip).toList(),
            ),
            const SizedBox(height: 14),
            const Text('Class',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int?>(
                  value: _classId,
                  isExpanded: true,
                  hint: const Text('All classes', style: TextStyle(fontSize: 13)),
                  items: [
                    const DropdownMenuItem<int?>(
                      child: Text('All classes', style: TextStyle(fontSize: 13)),
                    ),
                    ..._classesForProgram().map(
                      (c) => DropdownMenuItem<int?>(
                        value: c.classId,
                        child: Text(
                          '${c.className} — ${c.instructorName}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() => _classId = value);
                    _loadRecords();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  List<ClassOversight> _classesForProgram() {
    if (_program == 'All') return _classes;
    return _classes.where((c) => c.component == _program).toList();
  }

  Widget _programChip(String program) {
    final selected = _program == program;
    return ChoiceChip(
      label: Text(program, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) {
        if (_program == program) return;
        setState(() {
          _program = program;
          _classId = null;
        });
        _loadRecords();
      },
    );
  }

  Widget _buildSummary(DailyRecordsSummary summary) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Daily Summary',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _statCard('${summary.students}', 'Students',
                    Icons.groups, Colors.blueGrey),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _statCard('${summary.present}', 'Present',
                    Icons.check_circle, Colors.green),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _statCard('${summary.absent}', 'Absent',
                    Icons.cancel, Colors.red),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _statCard('${summary.partial}', 'Partial',
                    Icons.error_outline, Colors.amber.shade800),
              ),
            ],
          ),
          if (summary.excused > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.event_available,
                    size: 16, color: Colors.blueGrey.shade400),
                const SizedBox(width: 6),
                Text(
                  '${summary.excused} excused absence(s)',
                  style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade600),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _statCard(String value, String label, IconData icon, Color color) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold),
                ),
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 40),
        const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
        const SizedBox(height: 16),
        Text(_error!, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.grey)),
        const SizedBox(height: 20),
        Center(
          child: FilledButton.icon(
            onPressed: _loadRecords,
            style: FilledButton.styleFrom(backgroundColor: isuGreen),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Try again'),
          ),
        ),
      ],
    );
  }

  Widget _buildRecordsList() {
    final records = _data?.records ?? [];
    if (records.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No attendance records for this date and filter.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: records.length,
      itemBuilder: (context, index) => _buildStudentCard(records[index]),
    );
  }

  Widget _buildStudentCard(DailyRecordStudent student) {
    final color = _statusColor(student.status);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.2),
          child: Icon(_statusIcon(student.status), color: color, size: 20),
        ),
        title: Text(
          student.studentName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: Text(
          '${student.studentId} • ${student.courseAndSection}'
          '${student.className.isNotEmpty ? ' • ${student.className}' : ''}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              student.status,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            if (student.sessions.length > 1)
              Text(
                '${student.sessions.length} activities',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: student.sessions
                  .map(_buildSessionDetail)
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionDetail(DailyRecordSession s) {
    final color = s.attended
        ? (s.presenceStatus == 'Verified' && s.timeOut.isNotEmpty
            ? Colors.green
            : Colors.amber.shade800)
        : (s.excused ? Colors.blueGrey : Colors.red);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_statusIcon(s.excused ? 'Excused' : s.status),
                  size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${s.activity} (${s.activityDate} ${s.activityTime})',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 12),
                ),
              ),
              Text(
                s.status,
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold, color: color),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (s.attended) ...[
            _detailRow('Time In', s.timeIn),
            if (s.timeOut.isNotEmpty) _detailRow('Time Out', s.timeOut),
            if (s.presenceStatus.isNotEmpty)
              _detailRow('Presence', s.presenceStatus),
            _detailRow(
              'Checks',
              '${s.respondedChecks} answered, ${s.missedChecks} missed',
            ),
            _detailRow('Selfie', s.selfieVerified ? 'Verified' : 'Not verified'),
          ],
          if (s.sessionLatitude.isNotEmpty && s.sessionLongitude.isNotEmpty)
            _detailRow('Location', '${s.sessionLatitude}, ${s.sessionLongitude}'),
          if (s.remarks.isNotEmpty) _detailRow('Remarks', s.remarks),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11,
                color: Colors.grey.shade700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 11, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}
