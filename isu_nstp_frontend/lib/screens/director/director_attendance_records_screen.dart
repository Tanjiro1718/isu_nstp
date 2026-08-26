import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/api_config.dart';
import '../../models/user_model.dart';
import '../../services/director_service.dart';

/// Director's view of per-student attendance records across all classes.
///
/// The director picks a class from a dropdown (populated from the campus-wide
/// overview) and optionally narrows to a single date, then sees every student
/// row just like the instructor does — including the session's geofence
/// coordinates so the director knows which location the instructor chose.
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

  List<ClassOversight> _classes = [];
  ClassOversight? _selectedClass;
  List<Map<String, dynamic>> _records = [];
  Map<String, dynamic>? _summary;
  String? _selectedDate;
  bool _loadingClasses = true;
  bool _loadingRecords = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadClasses();
  }

  Future<void> _loadClasses() async {
    setState(() {
      _loadingClasses = true;
      _error = null;
    });

    try {
      final overview = await DirectorService.fetchOverview();
      final classes = overview.classes
          .where((c) => !c.noSessionsYet && !c.noStudentsYet)
          .toList();
      setState(() {
        _classes = classes;
        _loadingClasses = false;
        if (_classes.isNotEmpty) {
          _selectedClass = _classes.first;
          _loadRecords();
        }
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load classes: $e';
        _loadingClasses = false;
      });
    }
  }

  Future<void> _loadRecords() async {
    if (_selectedClass == null) return;

    setState(() {
      _loadingRecords = true;
      _error = null;
    });

    try {
      final url = ApiConfig.classAttendanceRecordsUrl(
        _selectedClass!.classId,
        date: _selectedDate,
      );
      final response = await http.get(
        Uri.parse(url),
        headers: {'ngrok-skip-browser-warning': 'true'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _records = (data['records'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          _summary = data['summary'] as Map<String, dynamic>?;
          _loadingRecords = false;
        });
      } else {
        final errBody = jsonDecode(response.body);
        setState(() {
          _error = errBody['error'] ?? 'Failed to load records';
          _loadingRecords = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Network error: $e';
        _loadingRecords = false;
      });
    }
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
        _selectedClass!.classId,
        date: _selectedDate,
        asCsv: true,
      );

      final response = await http.get(
        Uri.parse(url),
        headers: {'ngrok-skip-browser-warning': 'true'},
      );

      if (response.statusCode == 200) {
        final tempDir = await getTemporaryDirectory();
        final safeName =
            _selectedClass!.className.replaceAll(RegExp(r'[^\w\s-]'), '_');
        final suffix = _selectedDate ?? 'all-dates';
        final filename = 'attendance_${safeName}_$suffix.csv';
        final file = File('${tempDir.path}/$filename');
        await file.writeAsBytes(response.bodyBytes);

        await Share.shareXFiles(
          [XFile(file.path)],
          subject: 'Attendance Record: ${_selectedClass!.className}',
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
    return _loadingClasses
        ? const Center(child: CircularProgressIndicator(color: isuGreen))
        : _classes.isEmpty
            ? _buildEmptyState()
            : Column(
                children: [
                  _buildFilters(),
                  if (_summary != null) _buildSummary(),
                  Expanded(
                    child: _loadingRecords
                        ? const Center(
                            child: CircularProgressIndicator(color: isuGreen))
                        : _error != null
                            ? _buildErrorState()
                            : _buildRecordsList(),
                  ),
                ],
              );
  }

  Widget _buildEmptyState() {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Icon(Icons.inbox_outlined, size: 56, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(
          'No classes with sessions yet.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: isuGreen,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Once instructors create sessions and students check in, '
          'attendance records will appear here.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildErrorState() {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Icon(Icons.cloud_off, size: 56, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Colors.grey),
        ),
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

  Widget _buildFilters() {
    return Card(
      margin: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Class',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            DropdownButtonFormField<ClassOversight>(
              value: _selectedClass,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: _classes.map((cls) {
                return DropdownMenuItem(
                  value: cls,
                  child: Text(
                    '${cls.className} — ${cls.instructorName}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
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
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(width: 8),
                if (_selectedDate != null)
                  Chip(
                    label: Text(_selectedDate!,
                        style: const TextStyle(fontSize: 12)),
                    onDeleted: () {
                      setState(() => _selectedDate = null);
                      _loadRecords();
                    },
                    deleteIcon: const Icon(Icons.close, size: 16),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: const Text('Pick Date',
                      style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isuGreen,
                    side: BorderSide(color: isuGreen.withOpacity(0.4)),
                  ),
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
      color: isuGreen.withOpacity(0.06),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              'Attendance Rate: ${rate.toStringAsFixed(1)}%',
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: isuGreen),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _summaryChip('Expected', expected, Colors.grey),
                _summaryChip('Present', present, Colors.blue),
                _summaryChip('Absent', absent, Colors.orange),
                _summaryChip('Verified', verified, Colors.green),
                if (failed > 0) _summaryChip('Failed', failed, Colors.red),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryChip(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
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
      itemBuilder: (context, index) => _buildRecordCard(_records[index]),
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
    final activityDate = record['activity_date'] ?? '';
    final presenceStatus = record['presence_status'] ?? '';
    final attended = record['attended'] == true;
    final remarks = record['remarks'] ?? '';
    final sessionLat = record['session_latitude'] ?? '';
    final sessionLng = record['session_longitude'] ?? '';

    Color statusColor = attended ? Colors.green : Colors.red;
    if (presenceStatus == 'Failed') statusColor = Colors.orange;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.2),
          child: Icon(
            attended ? Icons.check_circle : Icons.cancel,
            color: statusColor,
            size: 20,
          ),
        ),
        title: Text(
          studentName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: Text('$studentId • $status',
            style: const TextStyle(fontSize: 12)),
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailRow('Activity', '$activity ($activityDate $activityTime)'),
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
                    record['selfie_verified'] == true ? 'Verified' : 'Not verified',
                  ),
                ],
                if (sessionLat.toString().isNotEmpty &&
                    sessionLng.toString().isNotEmpty) ...[
                  const Divider(height: 16),
                  Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 14, color: Colors.blue.shade600),
                      const SizedBox(width: 4),
                      Text(
                        'Instructor Location:',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: Colors.blue.shade700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Lat: $sessionLat, Lng: $sessionLng',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade700,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
                if (remarks.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _detailRow('Remarks', remarks, isRemark: true),
                ],
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
                fontSize: 12,
                color:
                    isRemark ? Colors.orange.shade700 : Colors.grey.shade700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: isRemark ? Colors.orange.shade900 : Colors.black87,
                fontStyle:
                    isRemark ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
