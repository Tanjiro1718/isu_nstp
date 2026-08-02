import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// How healthy a class or session looks at a glance.
enum Health { good, fair, attention, noData }

Health _parseHealth(String? raw) {
  switch (raw) {
    case 'good':
      return Health.good;
    case 'fair':
      return Health.fair;
    case 'attention':
      return Health.attention;
    default:
      return Health.noData;
  }
}

int _asInt(dynamic value) {
  if (value is int) return value;
  return int.tryParse('$value') ?? 0;
}

double _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0.0;
}

/// Campus-wide totals shown at the top of the oversight screen.
class CampusSummary {
  final int totalClasses;
  final int totalInstructors;
  final int totalStudents;
  final int totalSessions;
  final double attendanceRate;
  final int failedVerifications;
  final int classesNeedingAttention;
  final int classesWithoutSessions;
  final Health health;

  const CampusSummary({
    required this.totalClasses,
    required this.totalInstructors,
    required this.totalStudents,
    required this.totalSessions,
    required this.attendanceRate,
    required this.failedVerifications,
    required this.classesNeedingAttention,
    required this.classesWithoutSessions,
    required this.health,
  });

  factory CampusSummary.fromJson(Map<String, dynamic> json) => CampusSummary(
        totalClasses: _asInt(json['total_classes']),
        totalInstructors: _asInt(json['total_instructors']),
        totalStudents: _asInt(json['total_students']),
        totalSessions: _asInt(json['total_sessions']),
        attendanceRate: _asDouble(json['attendance_rate']),
        failedVerifications: _asInt(json['failed_verifications']),
        classesNeedingAttention: _asInt(json['classes_needing_attention']),
        classesWithoutSessions: _asInt(json['classes_without_sessions']),
        health: _parseHealth(json['health'] as String?),
      );
}

/// One class, the instructor assigned to it, and how its attendance looks.
class ClassOversight {
  final int classId;
  final String className;
  final String component;
  final String sectionCode;
  final int instructorId;
  final String instructorName;
  final String instructorEmail;
  final int studentCount;
  final int sessionCount;
  final String? lastSession;
  final int checkInCount;
  final int checkedOutCount;
  final int failedCount;
  final int warnedCount;
  final double attendanceRate;
  final Health health;
  final bool noSessionsYet;
  final bool noStudentsYet;

  const ClassOversight({
    required this.classId,
    required this.className,
    required this.component,
    required this.sectionCode,
    required this.instructorId,
    required this.instructorName,
    required this.instructorEmail,
    required this.studentCount,
    required this.sessionCount,
    required this.lastSession,
    required this.checkInCount,
    required this.checkedOutCount,
    required this.failedCount,
    required this.warnedCount,
    required this.attendanceRate,
    required this.health,
    required this.noSessionsYet,
    required this.noStudentsYet,
  });

  /// "CWTS - CWTS-1A", skipping whichever part is blank.
  String get subtitle =>
      [component, sectionCode].where((p) => p.isNotEmpty).join(' - ');

  factory ClassOversight.fromJson(Map<String, dynamic> json) => ClassOversight(
        classId: _asInt(json['class_id']),
        className: json['class_name'] as String? ?? 'Unnamed class',
        component: json['component'] as String? ?? '',
        sectionCode: json['section_code'] as String? ?? '',
        instructorId: _asInt(json['instructor_id']),
        instructorName: json['instructor_name'] as String? ?? 'Unassigned',
        instructorEmail: json['instructor_email'] as String? ?? '',
        studentCount: _asInt(json['student_count']),
        sessionCount: _asInt(json['session_count']),
        lastSession: json['last_session'] as String?,
        checkInCount: _asInt(json['check_in_count']),
        checkedOutCount: _asInt(json['checked_out_count']),
        failedCount: _asInt(json['failed_count']),
        warnedCount: _asInt(json['warned_count']),
        attendanceRate: _asDouble(json['attendance_rate']),
        health: _parseHealth(json['health'] as String?),
        noSessionsYet: json['no_sessions_yet'] == true,
        noStudentsYet: json['no_students_yet'] == true,
      );
}

/// The same classes rolled up per instructor.
class InstructorLoad {
  final int instructorId;
  final String instructorName;
  final String instructorEmail;
  final int classCount;
  final int studentCount;
  final int sessionCount;
  final int classesNeedingAttention;
  final List<String> classNames;

  const InstructorLoad({
    required this.instructorId,
    required this.instructorName,
    required this.instructorEmail,
    required this.classCount,
    required this.studentCount,
    required this.sessionCount,
    required this.classesNeedingAttention,
    required this.classNames,
  });

  factory InstructorLoad.fromJson(Map<String, dynamic> json) => InstructorLoad(
        instructorId: _asInt(json['instructor_id']),
        instructorName: json['instructor_name'] as String? ?? 'Unknown',
        instructorEmail: json['instructor_email'] as String? ?? '',
        classCount: _asInt(json['class_count']),
        studentCount: _asInt(json['student_count']),
        sessionCount: _asInt(json['session_count']),
        classesNeedingAttention: _asInt(json['classes_needing_attention']),
        classNames: (json['class_names'] as List<dynamic>? ?? [])
            .map((e) => '$e')
            .toList(),
      );
}

class DirectorOverview {
  final CampusSummary summary;
  final List<InstructorLoad> instructors;
  final List<ClassOversight> classes;

  const DirectorOverview({
    required this.summary,
    required this.instructors,
    required this.classes,
  });

  factory DirectorOverview.fromJson(Map<String, dynamic> json) =>
      DirectorOverview(
        summary: CampusSummary.fromJson(
          json['summary'] as Map<String, dynamic>? ?? const {},
        ),
        instructors: (json['instructors'] as List<dynamic>? ?? [])
            .map((e) => InstructorLoad.fromJson(e as Map<String, dynamic>))
            .toList(),
        classes: (json['classes'] as List<dynamic>? ?? [])
            .map((e) => ClassOversight.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// One activity inside a class.
class SessionOversight {
  final int sessionId;
  final String title;
  final String dateTime;
  final int expected;
  final int checkedIn;
  final int checkedOut;
  final int failed;
  final double attendanceRate;
  final Health health;
  final bool isCheckOutOpen;

  const SessionOversight({
    required this.sessionId,
    required this.title,
    required this.dateTime,
    required this.expected,
    required this.checkedIn,
    required this.checkedOut,
    required this.failed,
    required this.attendanceRate,
    required this.health,
    required this.isCheckOutOpen,
  });

  factory SessionOversight.fromJson(Map<String, dynamic> json) =>
      SessionOversight(
        sessionId: _asInt(json['session_id']),
        title: json['title'] as String? ?? 'Untitled activity',
        dateTime: json['date_time'] as String? ?? '',
        expected: _asInt(json['expected']),
        checkedIn: _asInt(json['checked_in']),
        checkedOut: _asInt(json['checked_out']),
        failed: _asInt(json['failed']),
        attendanceRate: _asDouble(json['attendance_rate']),
        health: _parseHealth(json['health'] as String?),
        isCheckOutOpen: json['is_check_out_open'] == true,
      );
}

class ClassSessionBreakdown {
  final int classId;
  final String className;
  final String instructorName;
  final int studentCount;
  final List<SessionOversight> sessions;

  const ClassSessionBreakdown({
    required this.classId,
    required this.className,
    required this.instructorName,
    required this.studentCount,
    required this.sessions,
  });

  factory ClassSessionBreakdown.fromJson(Map<String, dynamic> json) =>
      ClassSessionBreakdown(
        classId: _asInt(json['class_id']),
        className: json['class_name'] as String? ?? '',
        instructorName: json['instructor_name'] as String? ?? '',
        studentCount: _asInt(json['student_count']),
        sessions: (json['sessions'] as List<dynamic>? ?? [])
            .map((e) => SessionOversight.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class DirectorService {
  static const _headers = {'ngrok-skip-browser-warning': 'true'};

  /// Campus-wide oversight. Throws with a readable message so the screen can
  /// show it, rather than returning null and hiding the reason.
  static Future<DirectorOverview> fetchOverview({
    String? component,
    int? instructorId,
  }) async {
    final response = await http
        .get(
          Uri.parse(ApiConfig.directorOverviewUrl(
            component: component,
            instructorId: instructorId,
          )),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception('Could not load overview (${response.statusCode})');
    }
    return DirectorOverview.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  static Future<ClassSessionBreakdown> fetchClassSessions(int classId) async {
    final response = await http
        .get(
          Uri.parse(ApiConfig.directorClassSessionsUrl(classId)),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception('Could not load sessions (${response.statusCode})');
    }
    return ClassSessionBreakdown.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }
}
