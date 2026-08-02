import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

/// One student's live line in the instructor's headcount roster.
class RosterEntry {
  final int recordId;
  final String studentId;
  final String studentName;
  final String timeIn;
  final String? timeOut;

  /// 'standby' | 'checked_out' | 'failed'
  final String state;
  final String presenceStatus;

  /// Random presence pings: how many were sent and how many came back.
  final int checksTotal;
  final int checksResponded;
  final int checksMissed;
  final int checksAwaiting;

  const RosterEntry({
    required this.recordId,
    required this.studentId,
    required this.studentName,
    required this.timeIn,
    required this.timeOut,
    required this.state,
    required this.presenceStatus,
    required this.checksTotal,
    required this.checksResponded,
    required this.checksMissed,
    required this.checksAwaiting,
  });

  factory RosterEntry.fromJson(Map<String, dynamic> json) {
    int asInt(dynamic v) => v is int ? v : int.tryParse('$v') ?? 0;

    return RosterEntry(
      recordId: asInt(json['record_id']),
      studentId: json['student_id']?.toString() ?? '',
      studentName: json['student_name']?.toString() ?? 'Unknown',
      timeIn: json['time_in']?.toString() ?? '',
      timeOut: json['time_out']?.toString(),
      state: json['state']?.toString() ?? 'standby',
      presenceStatus: json['presence_status']?.toString() ?? 'ok',
      checksTotal: asInt(json['checks_total']),
      checksResponded: asInt(json['checks_responded']),
      checksMissed: asInt(json['checks_missed']),
      checksAwaiting: asInt(json['checks_awaiting']),
    );
  }

  bool get isStandby => state == 'standby';
  bool get isCheckedOut => state == 'checked_out';
  bool get hasFailed => state == 'failed';

  /// "2/3 answered" - the instructor's at-a-glance presence number.
  String get checkSummary =>
      checksTotal == 0 ? 'No checks yet' : '$checksResponded/$checksTotal answered';
}

/// Everything Monitor Headcounts needs for one activity.
class SessionRoster {
  final int sessionId;
  final String sessionTitle;
  final bool isCheckOutOpen;
  final int totalTimedIn;
  final int standby;
  final int checkedOut;
  final int warned;
  final int failed;
  final List<RosterEntry> students;

  const SessionRoster({
    required this.sessionId,
    required this.sessionTitle,
    required this.isCheckOutOpen,
    required this.totalTimedIn,
    required this.standby,
    required this.checkedOut,
    required this.warned,
    required this.failed,
    required this.students,
  });

  factory SessionRoster.fromJson(Map<String, dynamic> json) {
    int asInt(dynamic v) => v is int ? v : int.tryParse('$v') ?? 0;

    final counts = json['counts'];
    final countMap = counts is Map ? counts : const {};

    final rawStudents = json['students'];
    final entries = rawStudents is List
        ? rawStudents
            .whereType<Map>()
            .map((e) => RosterEntry.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <RosterEntry>[];

    return SessionRoster(
      sessionId: asInt(json['session_id']),
      sessionTitle: json['session_title']?.toString() ?? 'Activity',
      isCheckOutOpen: json['is_check_out_open'] == true,
      totalTimedIn: asInt(json['total_timed_in']),
      standby: asInt(countMap['standby']),
      checkedOut: asInt(countMap['checked_out']),
      warned: asInt(countMap['warned']),
      failed: asInt(countMap['failed']),
      students: entries,
    );
  }
}

class ActionResult {
  final bool success;
  final String message;
  const ActionResult(this.success, this.message);
}

/// Instructor-side calls for the live headcount panel.
class HeadcountService {
  static const _headers = {'ngrok-skip-browser-warning': 'true'};

  /// Live roster for one session. Returns null when the request fails so the
  /// caller can keep showing the previous snapshot.
  static Future<SessionRoster?> fetchRoster(int sessionId) async {
    try {
      final response = await http.get(
        Uri.parse(ApiConfig.sessionRosterUrl(sessionId)),
        headers: _headers,
      );
      if (response.statusCode != 200) return null;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      return SessionRoster.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Releases the time-out window so standby students can submit their photo.
  static Future<ActionResult> openCheckOut({
    required int sessionId,
    required int instructorUserId,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(ApiConfig.openCheckOutUrl),
        headers: const {
          'Content-Type': 'application/json',
          'ngrok-skip-browser-warning': 'true',
        },
        body: jsonEncode({
          'session_id': sessionId,
          'instructor_id': instructorUserId,
        }),
      );

      Map<String, dynamic> body = {};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {
        // Non-JSON error page; fall through to a generic message.
      }

      if (response.statusCode == 200) {
        return ActionResult(
          true,
          body['message']?.toString() ?? 'Time-out opened.',
        );
      }
      return ActionResult(
        false,
        body['error']?.toString() ??
            'Could not open time-out (${response.statusCode}).',
      );
    } catch (_) {
      return const ActionResult(false, 'Network error. Check your connection.');
    }
  }
}
