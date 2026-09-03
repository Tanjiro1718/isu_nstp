import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../config/api_config.dart';
import '../../models/user_model.dart';
import '../../services/headcount_service.dart';

class InstructorMonitorScreen extends StatefulWidget {
  /// Needed to authorise opening the time-out window. Optional so the screen
  /// still renders (read-only) if pushed without a signed-in instructor.
  final UserModel? instructor;

  /// True when the screen is shown as a tab inside a dashboard. The title and
  /// back arrow are dropped, but the actions stay as a slim toolbar - losing
  /// them would make Export unreachable.
  final bool embedded;

  const InstructorMonitorScreen({
    super.key,
    this.instructor,
    this.embedded = false,
  });

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
  bool _showStandbyRoster = false;

  // --- Geofence leave requests ---
  List<Map<String, dynamic>> _pendingLeaves = [];

  @override
  void initState() {
    super.initState();
    _fetchLogs();
    _fetchPendingLeaves();
    // Poll so newly answered presence checks and time-outs appear without the
    // instructor having to pull to refresh.
    _rosterPoller = Timer.periodic(
      const Duration(seconds: 20),
      (_) {
        _refreshRoster();
        _fetchPendingLeaves();
      },
    );
  }

  @override
  void dispose() {
    _rosterPoller?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Today, in the `MM/DD/YYYY` shape the log rows use.
  String get _todayStamp {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '$month/$day/${now.year}';
  }

  /// The session the instructor is running *today*.
  ///
  /// Scoped to today on purpose: the headcount is a live view of who is
  /// currently on site, so yesterday's roster must not still be sitting there
  /// this morning. The logs themselves are never discarded - they stay in the
  /// Attendance Record, which is where past days are meant to be read.
  int? get _activeSessionId {
    final today = _todayStamp;
    for (final log in _logs) {
      if (log['date']?.toString() != today) continue;
      final raw = log['session_id'];
      final id = raw is int ? raw : int.tryParse('$raw');
      if (id != null) return id;
    }
    return null;
  }

  Future<void> _refreshRoster() async {
    final sessionId = _activeSessionId;

    // Nothing running today - drop the panel rather than leave a stale
    // headcount from a previous day on screen.
    if (sessionId == null) {
      if (_roster != null && mounted) setState(() => _roster = null);
      return;
    }

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

  // ------------------------------------------------------------------
  // Geofence leave requests
  // ------------------------------------------------------------------

  Future<void> _fetchPendingLeaves() async {
    final instructorId = widget.instructor?.id;
    if (instructorId == null) return;

    try {
      final response = await http.get(
        Uri.parse(ApiConfig.pendingLeavesUrl(instructorId, status: 'all')),
        headers: {'ngrok-skip-browser-warning': 'true'},
      );

      if (response.statusCode == 200 && mounted) {
        final body = jsonDecode(response.body);
        final leaves = body['leaves'];
        if (leaves is List) {
          setState(() {
            _pendingLeaves = leaves.cast<Map<String, dynamic>>();
          });
        }
      }
    } catch (_) {
      // Polling failure should not disrupt the UI.
    }
  }

  Future<void> _reviewLeave(
    int leaveId,
    String decision, {
    String note = '',
  }) async {
    final instructorId = widget.instructor?.id;
    if (instructorId == null) return;

    try {
      final response = await http.patch(
        Uri.parse(ApiConfig.reviewLeaveUrl(leaveId)),
        headers: {
          'Content-Type': 'application/json',
          'ngrok-skip-browser-warning': 'true',
        },
        body: jsonEncode({
          'instructor_id': instructorId,
          'decision': decision,
          'response_note': note,
        }),
      );

      if (!mounted) return;

      String message = 'Leave request updated.';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['message'] != null) {
          message = body['message'].toString();
        }
      } catch (_) {}

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: response.statusCode == 200 ? Colors.green : Colors.red,
        ),
      );

      await _fetchPendingLeaves();
      await _refreshRoster();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Network error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _showReviewLeaveDialog(Map<String, dynamic> leave) {
    final noteController = TextEditingController();
    final studentName = leave['student_name']?.toString() ?? 'Student';
    final reason = leave['reason']?.toString() ?? '';
    final leaveId = leave['id'];
    final status = leave['status']?.toString() ?? 'pending';
    final secondsRemaining = leave['seconds_remaining'] ?? 0;
    final minutes = (secondsRemaining as int) ~/ 60;
    final seconds = (secondsRemaining as int) % 60;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              status == 'pending'
                  ? Icons.directions_walk
                  : (status == 'approved' ? Icons.check_circle : Icons.cancel),
              color: status == 'pending'
                  ? Colors.orange
                  : (status == 'approved' ? Colors.green : Colors.red),
              size: 28,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Leave Request',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _leaveDetailLine('Student', studentName),
              _leaveDetailLine('Reason', reason),
              if (status == 'pending' && secondsRemaining > 0)
                _leaveDetailLine(
                  'Time remaining',
                  '$minutes:${seconds.toString().padLeft(2, '0')}',
                ),
              _leaveDetailLine('Status', status.toUpperCase()),
              if (leave['response_note'] != null)
                _leaveDetailLine('Note', leave['response_note'].toString()),
              if (status == 'pending') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  maxLines: 2,
                  maxLength: 300,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Note (optional)',
                    hintText: 'Add a note for the student',
                    hintStyle: const TextStyle(fontSize: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
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
          if (status == 'pending') ...[
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _reviewLeave(leaveId, 'reject', note: noteController.text.trim());
              },
              child: const Text(
                'Reject',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _reviewLeave(leaveId, 'approve', note: noteController.text.trim());
              },
              style: FilledButton.styleFrom(backgroundColor: Colors.green),
              child: const Text('Approve'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _leaveDetailLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  /// Builds the leave requests panel shown above the standby panel.
  Widget _buildLeaveRequestsPanel() {
    if (_pendingLeaves.isEmpty) return const SizedBox.shrink();

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
                Icon(Icons.directions_walk, color: Colors.orange.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Geofence Leave Requests',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_pendingLeaves.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange.shade900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ..._pendingLeaves.map((leave) => _buildLeaveRow(leave)),
          ],
        ),
      ),
    );
  }

  Widget _buildLeaveRow(Map<String, dynamic> leave) {
    final studentName = leave['student_name']?.toString() ?? 'Student';
    final reason = leave['reason']?.toString() ?? '';
    final status = leave['status']?.toString() ?? 'pending';
    final secondsRemaining = leave['seconds_remaining'] ?? 0;
    final minutes = (secondsRemaining as int) ~/ 60;
    final seconds = (secondsRemaining as int) % 60;

    late final Color color;
    late final Color darkColor;
    late final IconData icon;
    late final String statusLabel;

    switch (status) {
      case 'approved':
        color = Colors.green;
        darkColor = Colors.green.shade900;
        icon = Icons.check_circle;
        statusLabel = secondsRemaining > 0
            ? 'Outside \u00b7 $minutes:${seconds.toString().padLeft(2, '0')} left'
            : 'Approved';
        break;
      case 'returned':
        color = Colors.blue;
        darkColor = Colors.blue.shade900;
        icon = Icons.login;
        statusLabel = 'Returned';
        break;
      case 'rejected':
        color = Colors.red;
        darkColor = Colors.red.shade900;
        icon = Icons.cancel;
        statusLabel = 'Rejected';
        break;
      case 'deserted':
        color = Colors.red;
        darkColor = Colors.red.shade900;
        icon = Icons.warning;
        statusLabel = 'Did not return';
        break;
      default:
        color = Colors.orange;
        darkColor = Colors.orange.shade900;
        icon = Icons.pending;
        statusLabel = 'Pending review';
    }

    return InkWell(
      onTap: () => _showReviewLeaveDialog(leave),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    studentName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  if (reason.isNotEmpty)
                    Text(
                      reason.length > 60
                          ? '${reason.substring(0, 60)}...'
                          : reason,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: darkColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fetchLogs() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Scope to this instructor's own sessions. Unfiltered, the newest log of
      // the day could belong to another instructor's activity - the roster
      // would show their students and "Open time-out" would be refused.
      final instructorId = widget.instructor?.id;
      final uri = Uri.parse(logsUrl).replace(
        queryParameters: instructorId == null
            ? null
            : {'instructor_id': '$instructorId'},
      );
      final response = await http.get(uri);

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

  /// Shares the visible logs as a real .csv attachment.
  ///
  /// This used to hand the CSV to Share.share() as plain text, which most apps
  /// paste into a message body - so what arrived was a wall of commas rather
  /// than a file anyone could open in Excel. Writing it to a temp file and
  /// sharing that lets the receiving app see a real spreadsheet, matching the
  /// Class Attendance Record export.
  Future<void> _exportLogs() async {
    final logs = _filteredLogs;

    // Sharing a header-only file looks like a broken export; say so instead.
    if (logs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No attendance records to export.')),
      );
      return;
    }

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
      ...logs.map((log) {
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

    final csv = rows.map((row) => row.map(_escapeCsv).join(',')).join('\r\n');

    try {
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/${_exportFilename()}');
      // Excel only honours UTF-8 in a CSV when the BOM is present; without it
      // any non-ASCII character in a name or address is mangled on open.
      await file.writeAsString('\uFEFF$csv');

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')],
        subject: 'NSTP Attendance Logs',
        text: 'NSTP attendance logs (${logs.length} record(s)).',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  /// Names the file after the filter that produced it, so an instructor who
  /// exports several ranges can tell the attachments apart.
  String _exportFilename() {
    String stamp(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    final String suffix;
    if (_dateFrom != null && _dateTo != null) {
      suffix = '${stamp(_dateFrom!)}_to_${stamp(_dateTo!)}';
    } else if (_dateFrom != null) {
      suffix = 'from_${stamp(_dateFrom!)}';
    } else if (_dateTo != null) {
      suffix = 'until_${stamp(_dateTo!)}';
    } else {
      suffix = 'all-dates';
    }

    return 'nstp_attendance_logs_$suffix.csv';
  }

  String _escapeCsv(String value) {
    // \r matters as well as \n now that rows are separated by CRLF - a stray
    // carriage return in an address would otherwise split the row on open.
    final needsQuotes = value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r');
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
    // No activity today. Say so explicitly - a panel that simply vanishes
    // overnight looks like a fault rather than the daily reset it is.
    if (roster == null) return _buildNoActivityToday();

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

              // Collapsible "Presence checks answered" section. Collapsed by
              // default so the panel stays clean; expanding reveals the
              // students still on standby.
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () =>
                    setState(() => _showStandbyRoster = !_showStandbyRoster),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.fact_check_outlined,
                          size: 18, color: Colors.orange),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Presence checks answered',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Text(
                          '${roster.standby} on standby',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange.shade900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _showStandbyRoster
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 20,
                        color: Colors.grey.shade600,
                      ),
                    ],
                  ),
                ),
              ),
              if (_showStandbyRoster) ...[
                const SizedBox(height: 8),
                Builder(builder: (context) {
                  final standby = roster.students
                      .where((e) => e.isStandby)
                      .toList();
                  if (standby.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No students on standby right now.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    );
                  }
                  return Column(
                    children: standby.map(_buildRosterRow).toList(),
                  );
                }),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Shown when no session has been run today.
  Widget _buildNoActivityToday() {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.event_available, color: Colors.grey.shade500),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'No activity running today',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'The live headcount starts fresh each day. Previous days '
                    'are saved in the Attendance Record.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
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

  /// Neutral placeholder shown when a submission has no time-out photo.
  Widget _buildNoPhotoPlaceholder() {
    return Container(
      color: Colors.grey.shade200,
      alignment: Alignment.center,
      child: Icon(
        Icons.person_outline,
        size: 26,
        color: Colors.grey.shade500,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredLogs = _filteredLogs;

    return Scaffold(
      appBar: AppBar(
        title: widget.embedded
            ? null
            : const Text('Real-time Headcount Counter'),
        toolbarHeight: widget.embedded ? 48 : null,
        automaticallyImplyLeading: !widget.embedded,
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh records',
            onPressed: _fetchLogs,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Export logs as CSV',
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
                  Builder(builder: (context) {
                    final photoCount = filteredLogs
                        .where((log) =>
                            (log['selfie_image_url']?.toString() ?? '').isNotEmpty)
                        .length;
                    return Row(
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
                            value: '$photoCount Photos',
                            icon: Icons.image_search,
                            color: Colors.teal,
                          ),
                        ),
                      ],
                    );
                  }),
                  const SizedBox(height: 16),
                  _buildLeaveRequestsPanel(),
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
                        final checkInTime = log['time']?.toString() ?? '';

                        return ListTile(
                          // Show the time-out selfie as a tidy rounded thumbnail;
                          // tap to view it large when one is available.
                          leading: GestureDetector(
                            onTap: hasPhoto
                                ? () => _showExpandedImage(selfieUrl, studentName)
                                : null,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: hasPhoto
                                    ? Image.network(
                                        selfieUrl,
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, _) =>
                                            _buildNoPhotoPlaceholder(),
                                      )
                                    : _buildNoPhotoPlaceholder(),
                              ),
                            ),
                          ),
                          title: Text(
                            studentName,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: true,
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${log['date'] ?? '--'} • ${log['session_title'] ?? '--'}'
                                '${(log['department']?.toString() ?? '').isNotEmpty ? ' • ${log['department']}' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (checkInTime.isNotEmpty)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.schedule,
                                        size: 13, color: Colors.green.shade700),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Checked in $checkInTime',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.green.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                          // Location icon opens just the map.
                          trailing: IconButton(
                            icon: const Icon(Icons.location_on,
                                color: Colors.redAccent),
                            tooltip: 'View Map Location',
                            onPressed: () => _showLocationOnlyDialog(log),
                          ),
                          // Tapping the middle of the tile opens the full record.
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