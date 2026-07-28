import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import '../../config/api_config.dart';

class InstructorMonitorScreen extends StatefulWidget {
  const InstructorMonitorScreen({super.key});

  @override
  State<InstructorMonitorScreen> createState() => _InstructorMonitorScreenState();
}

class _InstructorMonitorScreenState extends State<InstructorMonitorScreen> {
  final String logsUrl = ApiConfig.attendanceLogsUrl;
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  String? _errorMessage;
  List<Map<String, dynamic>> _logs = [];
  DateTime? _dateFrom;
  DateTime? _dateTo;

  @override
  void initState() {
    super.initState();
    _fetchLogs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchLogs() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http.get(Uri.parse(logsUrl));

      if (response.statusCode == 200) {
        final List<dynamic> decoded = jsonDecode(response.body);
        setState(() {
          _logs = decoded.cast<Map<String, dynamic>>();
        });
      } else {
        setState(() {
          _errorMessage = 'Unable to load attendance records. Error ${response.statusCode}.';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Network error while loading attendance records: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<Map<String, dynamic>> get _filteredLogs {
    final query = _searchController.text.trim().toLowerCase();

    return _logs.where((log) {
      final logDate = _parseDate(log['date']?.toString());
      final matchesFrom = _dateFrom == null || logDate == null || !logDate.isBefore(_dateFrom!);
      final matchesTo = _dateTo == null || logDate == null || !logDate.isAfter(_dateTo!);
      final searchableText = [
        log['student_id'],
        log['student_name'],
        log['department'],
        log['section_code'],
        log['session_title'],
        log['status'],
        log['mode'],
        log['address'],
      ].join(' ').toLowerCase();

      return matchesFrom && matchesTo && (query.isEmpty || searchableText.contains(query));
    }).toList();
  }

  DateTime? _parseDate(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split('/');
    if (parts.length != 3) return null;
    final month = int.tryParse(parts[0]);
    final day = int.tryParse(parts[1]);
    final year = int.tryParse(parts[2]);
    if (month == null || day == null || year == null) return null;
    return DateTime(year, month, day);
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: isFrom ? (_dateFrom ?? now) : (_dateTo ?? now),
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 1),
    );

    if (selected == null) return;
    setState(() {
      if (isFrom) {
        _dateFrom = selected;
      } else {
        _dateTo = selected;
      }
    });
  }

  Future<void> _exportLogs() async {
    final rows = <List<String>>[
      [
        'Student ID',
        'Department',
        'Student Name',
        'Time',
        'Date',
        'Activity',
        'Mode',
        'Address',
        'Location',
      ],
      ..._filteredLogs.map((log) {
        final lat = log['student_latitude']?.toString() ?? '--';
        final lng = log['student_longitude']?.toString() ?? '--';
        return [
          log['student_id']?.toString() ?? '--',
          log['department']?.toString() ?? '--',
          log['student_name']?.toString() ?? '--',
          log['time']?.toString() ?? '--',
          log['date']?.toString() ?? '--',
          log['session_title']?.toString() ?? '--',
          log['mode']?.toString() ?? '--',
          log['address']?.toString() ?? '--',
          '$lat, $lng',
        ];
      }),
    ];

    final csv = rows.map((row) => row.map(_escapeCsv).join(',')).join('\n');
    await Share.share(csv, subject: 'NSTP Attendance Logs');
  }

  String _escapeCsv(String value) {
    final needsQuotes = value.contains(',') || value.contains('"') || value.contains('\n');
    final escaped = value.replaceAll('"', '""');
    return needsQuotes ? '"$escaped"' : escaped;
  }

  // --- NEW: Shows just the expanded picture ---
  void _showExpandedImage(String imageUrl, String studentName) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: Stack(
            alignment: Alignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: InteractiveViewer(
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.cancel, color: Colors.white, size: 32),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // --- NEW: Shows just the map location and address ---
  void _showLocationOnlyDialog(Map<String, dynamic> log) {
    final latitude = double.tryParse(log['student_latitude']?.toString() ?? '');
    final longitude = double.tryParse(log['student_longitude']?.toString() ?? '');
    final address = log['address']?.toString() ?? 'No address recorded';
    final studentName = log['student_name']?.toString() ?? 'Student';

    if (latitude == null || longitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No GPS coordinates available for this record.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('$studentName\'s Location'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Address: $address',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: double.maxFinite,
                  height: 250,
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: LatLng(latitude, longitude),
                      initialZoom: 16,
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom,
                      ),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'ph.edu.isu.nstp.attendanceapp',
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: LatLng(latitude, longitude),
                            width: 42,
                            height: 42,
                            child: const Icon(
                              Icons.location_on,
                              color: Colors.red,
                              size: 42,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  // --- UPDATED: Full Details Dialog (Includes the width fixes) ---
  void _showRecordDialog(Map<String, dynamic> log) {
    final selfieUrl = log['selfie_image_url']?.toString();
    final hasPhoto = selfieUrl != null && selfieUrl.isNotEmpty;
    final imageUrl = selfieUrl ?? '';
    final latitude = double.tryParse(log['student_latitude']?.toString() ?? '');
    final longitude = double.tryParse(log['student_longitude']?.toString() ?? '');
    final hasMapLocation = latitude != null && longitude != null;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(log['student_name']?.toString() ?? 'Attendance Record'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasPhoto)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: double.maxFinite, // Fix for layout crash
                      height: 180,
                      child: Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                _detailLine('Student ID', log['student_id']?.toString() ?? '--'),
                _detailLine('Department', log['department']?.toString() ?? '--'),
                _detailLine('Section', log['section_code']?.toString() ?? '--'),
                _detailLine('Time', log['time']?.toString() ?? '--'),
                _detailLine('Date', log['date']?.toString() ?? '--'),
                _detailLine('Activity', log['session_title']?.toString() ?? '--'),
                _detailLine('Mode', log['mode']?.toString() ?? '--'),
                _detailLine('Address', log['address']?.toString() ?? '--'),
                _detailLine(
                  'Location',
                  '${log['student_latitude']?.toString() ?? '--'}, ${log['student_longitude']?.toString() ?? '--'}',
                ),
                if (hasMapLocation) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Geo Map',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: double.maxFinite, // Fix for layout crash
                      height: 220,
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: LatLng(latitude, longitude),
                          initialZoom: 16,
                          interactionOptions: const InteractionOptions(
                            flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom,
                          ),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'ph.edu.isu.nstp.attendanceapp',
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: LatLng(latitude, longitude),
                                width: 42,
                                height: 42,
                                child: const Icon(
                                  Icons.location_on,
                                  color: Colors.red,
                                  size: 42,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _detailLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text('$label: $value'),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredLogs = _filteredLogs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Real-time Headcount Counter'),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh records',
            onPressed: _fetchLogs,
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export logs',
            onPressed: _exportLogs,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchLogs,
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricCard(
                          title: 'Attendance Records',
                          value: '${filteredLogs.length} Submissions',
                          icon: Icons.assignment_ind,
                          color: Colors.blue,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildMetricCard(
                          title: 'Picture Submissions',
                          value: '${filteredLogs.where((log) => (log['selfie_image_url']?.toString() ?? '').isNotEmpty).length} With Selfie Proof',
                          icon: Icons.image_search,
                          color: Colors.teal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 260,
                        child: TextField(
                          controller: _searchController,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'Search',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _pickDate(isFrom: true),
                        icon: const Icon(Icons.date_range),
                        label: Text(
                          _dateFrom == null
                              ? 'Date From'
                              : 'From: ${_dateFrom!.month.toString().padLeft(2, '0')}/${_dateFrom!.day.toString().padLeft(2, '0')}/${_dateFrom!.year}',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _pickDate(isFrom: false),
                        icon: const Icon(Icons.date_range),
                        label: Text(
                          _dateTo == null
                              ? 'Date To'
                              : 'To: ${_dateTo!.month.toString().padLeft(2, '0')}/${_dateTo!.day.toString().padLeft(2, '0')}/${_dateTo!.year}',
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _dateFrom = null;
                            _dateTo = null;
                            _searchController.clear();
                          });
                        },
                        icon: const Icon(Icons.clear_all),
                        label: const Text('Clear Filters'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  
                  // Render the actual list of logs
                  if (filteredLogs.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24.0),
                        child: Text('No attendance records found matching your criteria.'),
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: filteredLogs.length,
                      separatorBuilder: (context, index) => const Divider(),
                      itemBuilder: (context, index) {
                        final log = filteredLogs[index];
                        
                        // Check if the student has a selfie picture submitted
                        final selfieUrl = log['selfie_image_url']?.toString();
                        final hasPhoto = selfieUrl != null && selfieUrl.isNotEmpty;
                        final studentName = log['student_name']?.toString() ?? 'Unknown Student';

                        return ListTile(
                          // Show the selfie if available; wrap in GestureDetector to view large image
                          leading: GestureDetector(
                            onTap: hasPhoto ? () => _showExpandedImage(selfieUrl, studentName) : null,
                            child: CircleAvatar(
                              radius: 24, 
                              backgroundColor: Colors.blueAccent.withOpacity(0.2),
                              backgroundImage: hasPhoto ? NetworkImage(selfieUrl) : null,
                              child: hasPhoto 
                                  ? null 
                                  : const Icon(Icons.person, color: Colors.blueAccent),
                            ),
                          ),
                          title: Text(studentName),
                          subtitle: Text(
                              '${log['date'] ?? '--'} • ${log['session_title'] ?? '--'} • ${log['department'] ?? ''}'),
                          // Location Icon now opens just the map
                          trailing: IconButton(
                            icon: const Icon(Icons.location_on, color: Colors.redAccent),
                            tooltip: 'View Map Location',
                            onPressed: () => _showLocationOnlyDialog(log),
                          ),
                          // Tapping the middle of the tile still opens the full record with all details
                          onTap: () => _showRecordDialog(log),
                        );
                      },
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}