import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../config/api_config.dart';
import '../../models/user_model.dart';
import '../../models/class_model.dart';
import '../../services/class_service.dart';
import '../../utils/file_download.dart';

class ClassAttendanceRecordsScreen extends StatefulWidget {
  final UserModel user;

  /// True when the screen is shown as a tab inside a dashboard. It then drops
  /// its own AppBar so the parent's bar is the only one on screen.
  final bool embedded;

  /// Optional deep-link target: the class and day to open first, so tapping a
  /// row in "My Sessions" lands straight on that activity's record.
  final int? initialClassId;
  final String? initialDate;

  const ClassAttendanceRecordsScreen({
    super.key,
    required this.user,
    this.embedded = false,
    this.initialClassId,
    this.initialDate,
  });

  @override
  State<ClassAttendanceRecordsScreen> createState() =>
      _ClassAttendanceRecordsScreenState();
}

class _ClassAttendanceRecordsScreenState
    extends State<ClassAttendanceRecordsScreen> {
  List<ClassModel> _classes = [];
  ClassModel? _selectedClass;
  List<Map<String, dynamic>> _records = [];
  Map<String, dynamic>? _summary;
  String? _selectedDate;
  bool _loadingClasses = true;
  bool _loadingRecords = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate;
    _loadClasses();
  }

  Future<void> _loadClasses() async {
    setState(() {
      _loadingClasses = true;
      _errorMessage = null;
    });

    try {
      final classes =
          await ClassService.fetchInstructorClasses(widget.user.id);
      setState(() {
        _classes = classes;
        _loadingClasses = false;
        if (_classes.isNotEmpty) {
          // Open the deep-linked class when there is one, else the first.
          _selectedClass = _classes.firstWhere(
            (c) => c.id == widget.initialClassId,
            orElse: () => _classes.first,
          );
          _loadRecords();
        }
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load classes: $e';
        _loadingClasses = false;
      });
    }
  }

  Future<Map<String, dynamic>> _fetchAttendance(
    int classId, {
    String? date,
  }) async {
    final url = ApiConfig.classAttendanceRecordsUrl(classId, date: date);
    final response = await http.get(
      Uri.parse(url),
      headers: {'ngrok-skip-browser-warning': 'true'},
    );

    if (response.statusCode != 200) {
      String message = 'Failed to load records';
      try {
        final error = jsonDecode(response.body);
        if (error is Map && error['error'] != null) {
          message = error['error'].toString();
        }
      } catch (_) {}
      throw _AttendanceFetchException(message);
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> _loadRecords() async {
    if (_selectedClass == null) return;

    setState(() {
      _loadingRecords = true;
      _errorMessage = null;
    });

    try {
      final data =
          await _fetchAttendance(_selectedClass!.id, date: _selectedDate);
      setState(() {
        _records = (data['records'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        _summary = data['summary'] as Map<String, dynamic>?;
        _loadingRecords = false;
      });
    } on _AttendanceFetchException catch (e) {
      setState(() {
        _errorMessage = e.message;
        _loadingRecords = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Network error: $e';
        _loadingRecords = false;
      });
    }
  }

  String _isoDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  String _displayDate(String isoDate) {
    final parsed = DateTime.tryParse(isoDate);
    if (parsed == null) return isoDate;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[parsed.month - 1]} ${parsed.day}, ${parsed.year}';
  }

  Future<void> _showAbsentStudents() async {
    final classGroup = _selectedClass;
    if (classGroup == null) return;

    final isToday = _selectedDate == null;
    final date = _selectedDate ?? _isoDate(DateTime.now());

    List<Map<String, dynamic>> records;
    if (isToday) {
      try {
        final data = await _fetchAttendance(classGroup.id, date: date);
        records = (data['records'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
      } on _AttendanceFetchException catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load absences: ${e.message}')),
        );
        return;
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load absences: $e')),
        );
        return;
      }
    } else {
      records = _records;
    }

    if (!mounted) return;

    final absent = records
        .where((row) => row['attended'] != true && row['status'] == 'Absent')
        .toList()
      ..sort((a, b) {
        final left = a['student_name']?.toString().toLowerCase() ?? '';
        final right = b['student_name']?.toString().toLowerCase() ?? '';
        return left.compareTo(right);
      });
    final excusedCount =
        records.where((row) => row['status'] == 'Excused').length;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.75,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.person_off_outlined,
                        color: Colors.orange.shade800,
                        size: 26,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Absent Students',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${classGroup.name} • '
                              '${isToday ? 'Today, ' : ''}'
                              '${_displayDate(date)}',
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
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Text(
                          '${absent.length}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (absent.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(28),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            size: 40,
                            color: Colors.green.shade400,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'No absent students for ${_displayDate(date)}.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: absent.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, index) => _absentRow(absent[index]),
                    ),
                  ),
                if (excusedCount > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Text(
                      '$excusedCount approved excuse(s) on this day, not counted '
                      'as absent.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _absentRow(Map<String, dynamic> record) {
    final name = record['student_name']?.toString() ?? 'Unknown Student';
    final studentId = record['student_id']?.toString() ?? '--';
    final section = record['course_and_section']?.toString() ?? '';
    final activity = record['activity']?.toString() ?? '';
    final activityTime = record['activity_time']?.toString() ?? '';
    final remarks = record['remarks']?.toString() ?? '';

    final identity = [studentId, if (section.isNotEmpty) section].join(' • ');
    final activityLine = [
      if (activity.isNotEmpty) activity,
      if (activityTime.isNotEmpty) activityTime,
    ].join(' • ');

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: CircleAvatar(
        backgroundColor: Colors.orange.withValues(alpha: 0.15),
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: Colors.orange.shade900,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(
        name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(identity, style: const TextStyle(fontSize: 12)),
          if (activityLine.isNotEmpty)
            Text(
              activityLine,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          if (remarks.isNotEmpty)
            Text(
              remarks,
              style: TextStyle(
                fontSize: 11,
                color: Colors.orange.shade800,
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate != null
          ? DateTime.parse(_selectedDate!)
          : DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (picked != null) {
      setState(() {
        _selectedDate =
            '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      });
      _loadRecords();
    }
  }

  Future<void> _exportCsv() async {
    if (_selectedClass == null || _records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No records to export')),
      );
      return;
    }

    try {
      final url = ApiConfig.classAttendanceRecordsUrl(
        _selectedClass!.id,
        date: _selectedDate,
        asCsv: true,
      );

      final response = await http.get(
        Uri.parse(url),
        headers: {'ngrok-skip-browser-warning': 'true'},
      );

      if (response.statusCode == 200) {
        final safeName =
            _selectedClass!.name.replaceAll(RegExp(r'[^\w\s-]'), '_');
        final suffix = _selectedDate ?? 'all-dates';
        final filename = 'attendance_${safeName}_$suffix.csv';

        await saveOrShareFile(
          bytes: response.bodyBytes,
          filename: filename,
          mimeType: 'text/csv',
          subject: 'Attendance Record: ${_selectedClass!.name}',
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: ${response.statusCode}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: const Text('Class Attendance Record'),
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
              elevation: 2,
            ),
      body: _loadingClasses
          ? const Center(child: CircularProgressIndicator())
          : _classes.isEmpty
              ? const Center(
                  child: Text('No classes found. Create a class first.'))
              : Column(
                  children: [
                    _buildFilters(),
                    if (_summary != null) _buildSummary(),
                    Expanded(
                      child: _loadingRecords
                          ? const Center(child: CircularProgressIndicator())
                          : _errorMessage != null
                              ? Center(child: Text(_errorMessage!))
                              : _buildRecordsList(),
                    ),
                  ],
                ),
      floatingActionButton: _records.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _exportCsv,
              icon: const Icon(Icons.share),
              label: const Text('Share CSV'),
              backgroundColor: Colors.green,
            )
          : null,
    );
  }

  Widget _buildFilters() {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Class', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            DropdownButtonFormField<ClassModel>(
              initialValue: _selectedClass,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: _classes.map((cls) {
                return DropdownMenuItem(
                  value: cls,
                  child: Text(
                    '${cls.name} (${cls.studentCount} students)',
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: (cls) {
                setState(() {
                  _selectedClass = cls;
                  _selectedDate = null;
                });
                _loadRecords();
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Date Filter',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                if (_selectedDate != null)
                  Chip(
                    label: Text(_selectedDate!),
                    onDeleted: () {
                      setState(() => _selectedDate = null);
                      _loadRecords();
                    },
                  ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: const Text('Pick Date'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummary() {
    final sum = _summary!;
    final expected = sum['expected'] ?? 0;
    final present = sum['present'] ?? 0;
    final absent = sum['absent'] ?? 0;
    final verified = sum['verified'] ?? 0;
    final failed = sum['failed'] ?? 0;
    final rate = (sum['attendance_rate'] ?? 0.0).toDouble();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              'Attendance Rate: ${rate.toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _summaryChip('Expected', expected, Colors.grey),
                _summaryChip('Present', present, Colors.blue),
                _summaryChip(
                  'Absent',
                  absent,
                  Colors.orange,
                  onTap: _showAbsentStudents,
                ),
                _summaryChip('Verified', verified, Colors.green),
                if (failed > 0) _summaryChip('Failed', failed, Colors.red),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryChip(
    String label,
    int count,
    Color color, {
    VoidCallback? onTap,
  }) {
    final chip = Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right, size: 14, color: color),
          ],
        ),
      ],
    );

    if (onTap == null) return chip;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: chip,
      ),
    );
  }

  Widget _buildRecordsList() {
    if (_records.isEmpty) {
      return const Center(
        child: Text('No attendance records for the selected filter.'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _records.length,
      itemBuilder: (context, index) {
        final record = _records[index];
        return _buildRecordCard(record);
      },
    );
  }

  Widget _buildRecordCard(Map<String, dynamic> record) {
    final studentName = record['student_name'] ?? '';
    final studentId = record['student_id'] ?? '';
    final status = record['status'] ?? '';
    final timeIn = record['time_in'] ?? '';
    final timeOut = record['time_out'] ?? '';
    final activity = record['activity'] ?? '';
    final activityTime = record['activity_time'] ?? '';
    final presenceStatus = record['presence_status'] ?? '';
    final attended = record['attended'] == true;
    final remarks = record['remarks'] ?? '';

    Color statusColor = attended ? Colors.green : Colors.red;
    if (presenceStatus == 'Failed') statusColor = Colors.orange;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.2),
          child: Icon(
            attended ? Icons.check_circle : Icons.cancel,
            color: statusColor,
          ),
        ),
        title: Text(
          studentName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text('$studentId • $status'),
        // Show the check-in time at a glance on the collapsed card.
        trailing: attended && timeIn.isNotEmpty
            ? Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.schedule, size: 14, color: Colors.green.shade800),
                    const SizedBox(width: 4),
                    Text(
                      'In: $timeIn',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.green.shade800,
                      ),
                    ),
                  ],
                ),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailRow('Activity', '$activity ($activityTime)'),
                if (attended) ...[
                  _detailRow('Time In', timeIn),
                  if (timeOut.isNotEmpty) _detailRow('Time Out', timeOut),
                  if (presenceStatus.isNotEmpty)
                    _detailRow('Presence', presenceStatus),
                  _detailRow(
                    'Checks',
                    '${record['responded_checks']} answered, ${record['missed_checks']} missed',
                  ),
                  _detailRow(
                    'Selfie',
                    record['selfie_verified'] == true ? 'Yes' : 'No',
                  ),
                ],
                if (remarks.isNotEmpty)
                  _detailRow('Remarks', remarks, isRemark: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, {bool isRemark = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isRemark ? Colors.orange.shade700 : Colors.grey.shade700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: isRemark ? Colors.orange.shade900 : Colors.black87,
                fontStyle: isRemark ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendanceFetchException implements Exception {
  final String message;

  _AttendanceFetchException(this.message);

  @override
  String toString() => message;
}
