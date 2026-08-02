import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import '../../config/api_config.dart';
import '../../models/user_model.dart';
import '../../services/headcount_service.dart';

class InstructorMonitorScreen extends StatefulWidget {
  /// Needed to authorise opening the time-out window. Optional so the screen
  /// still renders (read-only) if pushed without a signed-in instructor.
  final UserModel? instructor;

  const InstructorMonitorScreen({super.key, this.instructor});

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

  // --- Live standby roster for the newest activity ---
  SessionRoster? _roster;
  Timer? _rosterPoller;
  bool _isOpeningCheckOut = false;

  @override
  void initState() {
    super.initState();
    _fetchLogs();
    // Poll so newly answered presence checks and time-outs appear without the
    // instructor having to pull to refresh.
    _rosterPoller = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _refreshRoster(),
    );
  }

  @override
  void dispose() {
    _rosterPoller?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// The most recent session id present in the logs - that is the activity the
  /// instructor is currently running.
  int? get _activeSessionId {
    for (final log in _logs) {
      final raw = log['session_id'];
      final id = raw is int ? raw : int.tryParse('$raw');
      if (id != null) return id;
    }
    return null;
  }

  Future<void> _refreshRoster() async {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;

    final roster = await HeadcountService.fetchRoster(sessionId);
    // Null means the request failed; keep the previous snapshot on screen.
    if (roster != null && mounted) {
      setState(() => _roster = roster);
    }
  }

  Future<void> _openCheckOut() async {
    final sessionId = _activeSessionId;
    final instructor = widget.instructor;
    if (sessionId == null || instructor == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Open time-out?'),
        content: Text(
          'Students on standby for "${_roster?.sessionTitle ?? 'this activity'}" '
          'will be notified that they may submit their time-out photo. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open time-out'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isOpeningCheckOut = true);
    final result = await HeadcountService.openCheckOut(
      sessionId: sessionId,
      instructorUserId: instructor.id,
    );

    if (!mounted) return;
    setState(() => _isOpeningCheckOut = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message),
        backgroundColor: result.success ? Colors.green : Colors.red,
      ),
    );
    await _refreshRoster();
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
        // Logs drive which session the roster shows, so refresh it after.
        await _refreshRoster();
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

  /// Standby panel: who is waiting to time out, how many random presence checks
  /// each student has answered, and the button that releases time-out.
  Widget _buildStandbyPanel() {
    final roster = _roster;
    if (roster == null) return const SizedBox.shrink();

    final canOpen = widget.instructor != null &&
        !roster.isCheckOutOpen &&
        !_isOpeningCheckOut;

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  roster.isCheckOutOpen ? Icons.lock_open : Icons.hourglass_top,
                  color: roster.isCheckOutOpen ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    roster.sessionTitle,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              roster.isCheckOutOpen
                  ? 'Time-out is OPEN. Students may submit their time-out photo.'
                  : '${roster.standby} student(s) on standby. They cannot time out '
                        'until you open the window.',
              style: TextStyle(
                fontSize: 13,
                color: roster.isCheckOutOpen
                    ? Colors.green.shade800
                    : Colors.orange.shade900,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),

            // Headline counts.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildCountChip('Timed in', roster.totalTimedIn, Colors.blue),
                _buildCountChip('On standby', roster.standby, Colors.orange),
                _buildCountChip('Timed out', roster.checkedOut, Colors.green),
                if (roster.warned > 0)
                  _buildCountChip('Warned', roster.warned, Colors.amber),
                if (roster.failed > 0)
                  _buildCountChip('Failed', roster.failed, Colors.red),
              ],
            ),
            const SizedBox(height: 12),

            if (!roster.isCheckOutOpen)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: canOpen ? _openCheckOut : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: _isOpeningCheckOut
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.lock_open),
                  label: Text(
                    _isOpeningCheckOut
                        ? 'Opening...'
                        : 'Open time-out for everyone',
                  ),
                ),
              ),

            if (roster.students.isNotEmpty) ...[
              const Divider(height: 24),
              const Text(
                'Presence checks answered',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 8),
              ...roster.students.map(_buildRosterRow),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCountChip(String label, int value, MaterialColor color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.shade50,
        border: Border.all(color: color.shade200),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color.shade900,
        ),
      ),
    );
  }

  Widget _buildRosterRow(RosterEntry entry) {
    late final Color color;
    late final IconData icon;
    late final String stateLabel;

    if (entry.isCheckedOut) {
      color = Colors.green;
      icon = Icons.task_alt;
      stateLabel = 'Timed out ${entry.timeOut ?? ''}'.trim();
    } else if (entry.hasFailed) {
      color = Colors.red;
      icon = Icons.gpp_bad;
      stateLabel = 'Failed verification';
    } else if (entry.checksAwaiting > 0) {
      color = Colors.deepOrange;
      icon = Icons.notifications_active;
      stateLabel = 'Awaiting response';
    } else {
      color = Colors.orange;
      icon = Icons.hourglass_bottom;
      stateLabel = 'On standby';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.studentName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  'In ${entry.timeIn} • $stateLabel',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          // The headline number the instructor asked for: how many of the random
          // pings this student actually pushed back on.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              entry.checkSummary,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ],
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
                  _buildStandbyPanel(),
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
                              backgroundColor: Colors.blueAccent.withValues(alpha: 0.2),
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