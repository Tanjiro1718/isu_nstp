import 'dart:convert';
import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// Live state of a student's attendance while an activity is running.
class PresenceStatus {
  final bool hasRecord;
  final int? recordId;
  final int? sessionId;
  final String sessionTitle;

  /// 'ok' | 'warned' | 'failed'
  final String presenceStatus;
  final int missedChecks;
  final bool canCheckOut;

  /// False until the instructor releases time-out for the whole session.
  final bool checkOutOpen;
  final bool checkedOut;
  final int totalChecks;
  final int respondedChecks;

  /// Set when a random check is waiting for an answer right now.
  final int? pendingCheckId;
  final int pendingSecondsRemaining;

  const PresenceStatus({
    required this.hasRecord,
    this.recordId,
    this.sessionId,
    this.sessionTitle = '',
    this.presenceStatus = 'ok',
    this.missedChecks = 0,
    this.canCheckOut = false,
    this.checkOutOpen = false,
    this.checkedOut = false,
    this.totalChecks = 0,
    this.respondedChecks = 0,
    this.pendingCheckId,
    this.pendingSecondsRemaining = 0,
  });

  bool get hasPendingCheck => pendingCheckId != null;
  bool get isFailed => presenceStatus == 'failed';
  bool get isWarned => presenceStatus == 'warned';

  /// Timed in, presence still good, but the instructor has not opened time-out.
  bool get isOnStandby =>
      hasRecord && !checkedOut && !isFailed && !checkOutOpen;

  factory PresenceStatus.fromJson(Map<String, dynamic> json) {
    final pending = json['pending_check'] as Map<String, dynamic>?;
    return PresenceStatus(
      hasRecord: json['has_record'] == true,
      recordId: json['record_id'] as int?,
      sessionId: json['session_id'] as int?,
      sessionTitle: json['session_title'] as String? ?? '',
      presenceStatus: json['presence_status'] as String? ?? 'ok',
      missedChecks: json['missed_checks'] as int? ?? 0,
      canCheckOut: json['can_check_out'] == true,
      checkOutOpen: json['check_out_open'] == true,
      checkedOut: json['checked_out'] == true,
      totalChecks: json['total_checks'] as int? ?? 0,
      respondedChecks: json['responded_checks'] as int? ?? 0,
      pendingCheckId: pending?['check_id'] as int?,
      pendingSecondsRemaining: pending?['seconds_remaining'] as int? ?? 0,
    );
  }
}

/// Result of an action the student took (respond / check out).
class PresenceActionResult {
  final bool success;
  final String message;

  const PresenceActionResult(this.success, this.message);
}

class PresenceService {
  /// Polls the backend for the current presence state.
  ///
  /// Returns null on a network error so the caller can simply keep the last
  /// known state rather than flashing an error during a brief dropout.
  static Future<PresenceStatus?> fetchStatus(
    int studentUserId, {
    int? sessionId,
  }) async {
    try {
      final response = await http
          .get(Uri.parse(
            ApiConfig.presenceStatusUrl(studentUserId, sessionId: sessionId),
          ))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return PresenceStatus.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Confirms the student is still inside the geofence.
  static Future<PresenceActionResult> respondToCheck({
    required int checkId,
    required int studentUserId,
  }) async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final response = await http.post(
        Uri.parse(ApiConfig.presenceRespondUrl),
        body: {
          'check_id': checkId.toString(),
          'student_id': studentUserId.toString(),
          'latitude': position.latitude.toString(),
          'longitude': position.longitude.toString(),
        },
      ).timeout(const Duration(seconds: 20));

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        return PresenceActionResult(
          true,
          body['message'] as String? ?? 'Presence confirmed.',
        );
      }
      return PresenceActionResult(
        false,
        body['error'] as String? ?? 'Could not confirm your presence.',
      );
    } catch (e) {
      return PresenceActionResult(false, 'Could not confirm presence: $e');
    }
  }

  /// Submits the time-out photo. The server rejects this outright when the
  /// student's presence verification has already failed.
  static Future<PresenceActionResult> checkOut({
    required int recordId,
    required int studentUserId,
    File? selfie,
  }) async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiConfig.attendanceCheckOutUrl),
      );
      request.fields['record_id'] = recordId.toString();
      request.fields['student_id'] = studentUserId.toString();
      request.fields['latitude'] = position.latitude.toString();
      request.fields['longitude'] = position.longitude.toString();

      if (selfie != null) {
        request.files.add(
          await http.MultipartFile.fromPath('selfie', selfie.path),
        );
      }

      final streamed = await request.send().timeout(
            const Duration(seconds: 30),
          );
      final body = await streamed.stream.bytesToString();
      final decoded = jsonDecode(body) as Map<String, dynamic>;

      if (streamed.statusCode == 200) {
        return PresenceActionResult(
          true,
          decoded['message'] as String? ?? 'Checked out successfully.',
        );
      }
      return PresenceActionResult(
        false,
        decoded['error'] as String? ?? 'Check-out was refused.',
      );
    } catch (e) {
      return PresenceActionResult(false, 'Check-out failed: $e');
    }
  }
}
