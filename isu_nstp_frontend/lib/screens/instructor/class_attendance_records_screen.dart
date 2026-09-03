import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../config/api_config.dart';
import '../../models/user_model.dart';
import '../../models/class_model.dart';
import '../../services/class_service.dart';

class ClassAttendanceRecordsScreen extends StatefulWidget {
  final UserModel user;

  /// True when the screen is shown as a tab inside a dashboard. It then drops
  /// its own AppBar so the parent's bar is the only one on screen.
  final bool embedded;

  const ClassAttendanceRecordsScreen({
    super.key,
    required this.user,
    this.embedded = false,
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
          _selectedClass = _classes.first;
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

  Future<void> _loadRecords() async {
    if (_selectedClass == null) return;

    setState(() {
      _loadingRecords = true;
      _errorMessage = null;
    });

    try {
      final url = ApiConfig.classAttendanceRecordsUrl(
        _selectedClass!.id,
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
        final error = jsonDecode(response.body);
        setState(() {
          _errorMessage = error['error'] ?? 'Failed to load records';
          _loadingRecords = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Network error: $e';
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
        _selectedClass!.id,
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
            _selectedClass!.name.replaceAll(RegExp(r'[^\w\s-]'), '_');
        final suffix = _selectedDate ?? 'all-dates';
        final filename = 'attendance_${safeName}_$suffix.csv';
        final file = File('${tempDir.path}/$filename');
        await file.writeAsBytes(response.bodyBytes);

        await Share.shareXFiles(
          [XFile(file.path)],
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
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
