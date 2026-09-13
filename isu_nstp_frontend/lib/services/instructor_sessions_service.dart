import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

/// One session the instructor created, as returned by
/// `GET /api/instructor/sessions/`.
class InstructorSession {
  final int sessionId;
  final String title;
  final int classId;
  final String className;
  final String dateTime;
  final DateTime dateTimeIso;
  final String status;
  final bool isCheckOutOpen;
  final bool isCancelled;
  final String? cancelledAt;
  final int expected;
  final int checkedIn;
  final int checkedOut;
  final double attendanceRate;

  const InstructorSession({
    required this.sessionId,
    required this.title,
    required this.classId,
    required this.className,
    required this.dateTime,
    required this.dateTimeIso,
    required this.status,
    required this.isCheckOutOpen,
    required this.isCancelled,
    required this.cancelledAt,
    required this.expected,
    required this.checkedIn,
    required this.checkedOut,
    required this.attendanceRate,
  });

  /// True for a session that has not finished yet (upcoming or running).
  bool get isUpcoming => status == 'Upcoming' || status == 'Ongoing';
  bool get isOngoing => status == 'Ongoing';

  /// Cancellable while it has not finished and has not already been called off.
  bool get canCancel => !isCancelled && status != 'Completed';

  /// Local calendar date (YYYY-MM-DD) so the attendance record can be opened
  /// on the day this session belongs to.
  String get localDate {
    final local = dateTimeIso.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  factory InstructorSession.fromJson(Map<String, dynamic> json) {
    return InstructorSession(
      sessionId: _asInt(json['session_id']),
      title: json['title']?.toString() ?? 'Attendance',
      classId: _asInt(json['class_id']),
      className: json['class_name']?.toString() ?? 'Unassigned',
      dateTime: json['date_time']?.toString() ?? '',
      dateTimeIso:
          DateTime.tryParse(json['date_time_iso']?.toString() ?? '')?.toUtc() ??
              DateTime.now().toUtc(),
      status: json['status']?.toString() ?? 'Completed',
      isCheckOutOpen: json['is_check_out_open'] == true,
      isCancelled: json['is_cancelled'] == true,
      cancelledAt: json['cancelled_at']?.toString(),
      expected: _asInt(json['expected']),
      checkedIn: _asInt(json['checked_in']),
      checkedOut: _asInt(json['checked_out']),
      attendanceRate: _asDouble(json['attendance_rate']),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? 0.0;
  }
}

/// Network calls for the instructor's session list.
class InstructorSessionsService {
  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    // ngrok free tier otherwise serves an HTML interstitial page.
    'ngrok-skip-browser-warning': 'true',
  };

  static Future<List<InstructorSession>> fetch(int instructorId) async {
    final response = await http.get(
      Uri.parse(ApiConfig.instructorSessionsUrl(instructorId)),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw Exception('Could not load your sessions (${response.statusCode}).');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final sessions = (decoded['sessions'] as List<dynamic>? ?? []);
    return sessions
        .map((e) => InstructorSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Calls off an upcoming or running session. Throws with the server's own
  /// message when it refuses (not the owner, already finished, already
  /// cancelled).
  static Future<void> cancel(int sessionId, int instructorId) async {
    final response = await http.post(
      Uri.parse(ApiConfig.cancelInstructorSessionUrl(sessionId)),
      headers: _headers,
      body: jsonEncode({'instructor_id': instructorId}),
    );

    if (response.statusCode != 200) {
      String message = 'Could not cancel the session (${response.statusCode}).';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] != null) {
          message = decoded['error'].toString();
        }
      } catch (_) {
        // Keep the status-code message.
      }
      throw Exception(message);
    }
  }
}
