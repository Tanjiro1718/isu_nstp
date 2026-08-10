import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/class_model.dart';

/// Thrown when the API responds with an error so the UI can show the reason.
class ClassApiException implements Exception {
  final String message;
  ClassApiException(this.message);

  @override
  String toString() => message;
}

/// All network calls for class groups, invitations and enrollments.
class ClassService {
  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    // ngrok free tier otherwise serves an HTML interstitial page.
    'ngrok-skip-browser-warning': 'true',
  };

  /// Pulls the message the backend sent, falling back to a generic one.
  static String _errorFrom(http.Response response, String fallback) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map) {
        return (body['error'] ?? body['detail'] ?? body['message'] ?? fallback)
            .toString();
      }
    } catch (_) {
      // Body was not JSON (e.g. an HTML error page).
    }
    return fallback;
  }

  // -------------------------------------------------------------------
  // Instructor side
  // -------------------------------------------------------------------

  /// Every class owned by [instructorId].
  static Future<List<ClassModel>> fetchInstructorClasses(
    int instructorId,
  ) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.classesUrl}?instructor_id=$instructorId'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ClassApiException(_errorFrom(response, 'Failed to load classes.'));
    }

    final List<dynamic> data = jsonDecode(response.body);
    return data.map((json) => ClassModel.fromJson(json)).toList();
  }

  /// Creates a class. The backend generates the join code and invite link.
  static Future<ClassModel> createClass({
    required int instructorId,
    required String name,
    required String component,
    String sectionCode = '',
    String description = '',
    bool requiresApproval = false,
  }) async {
    final response = await http.post(
      Uri.parse(ApiConfig.classesUrl),
      headers: _headers,
      body: jsonEncode({
        'instructor': instructorId,
        'name': name,
        'component': component,
        'section_code': sectionCode,
        'description': description,
        'requires_approval': requiresApproval,
      }),
    );

    if (response.statusCode != 201) {
      throw ClassApiException(_errorFrom(response, 'Failed to create class.'));
    }

    return ClassModel.fromJson(jsonDecode(response.body));
  }

  /// A single class including its member roster.
  static Future<ClassModel> fetchClassDetail(int classId) async {
    final response = await http.get(
      Uri.parse(ApiConfig.classDetailUrl(classId)),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ClassApiException(_errorFrom(response, 'Failed to load class.'));
    }

    return ClassModel.fromJson(jsonDecode(response.body));
  }

  /// Toggles joining on/off or flips the approval requirement.
  static Future<ClassModel> updateClass(
    int classId,
    Map<String, dynamic> changes,
  ) async {
    final response = await http.patch(
      Uri.parse(ApiConfig.classDetailUrl(classId)),
      headers: _headers,
      body: jsonEncode(changes),
    );

    if (response.statusCode != 200) {
      throw ClassApiException(_errorFrom(response, 'Failed to update class.'));
    }

    return ClassModel.fromJson(jsonDecode(response.body));
  }

  static Future<void> deleteClass(int classId) async {
    final response = await http.delete(
      Uri.parse(ApiConfig.classDetailUrl(classId)),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ClassApiException(_errorFrom(response, 'Failed to delete class.'));
    }
  }

  /// Issues a fresh join code, which revokes the previous one.
  static Future<String> rotateJoinCode(int classId) async {
    final response = await http.post(
      Uri.parse(ApiConfig.rotateJoinCodeUrl(classId)),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ClassApiException(_errorFrom(response, 'Failed to reset code.'));
    }

    return jsonDecode(response.body)['join_code']?.toString() ?? '';
  }

  /// Approves a pending student (status `active`) or restores a removed one.
  static Future<void> updateEnrollmentStatus(
    int enrollmentId,
    String status,
  ) async {
    final response = await http.patch(
      Uri.parse(ApiConfig.enrollmentUrl(enrollmentId)),
      headers: _headers,
      body: jsonEncode({'status': status}),
    );

    if (response.statusCode != 200) {
      throw ClassApiException(_errorFrom(response, 'Failed to update student.'));
    }
  }

  /// Removes a student from the roster (soft delete on the backend).
  static Future<void> removeStudent(int enrollmentId) async {
    final response = await http.delete(
      Uri.parse(ApiConfig.enrollmentUrl(enrollmentId)),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ClassApiException(_errorFrom(response, 'Failed to remove student.'));
    }
  }

  // -------------------------------------------------------------------
  // Student side
  // -------------------------------------------------------------------

  /// Joins a class using the code the instructor shared.
  static Future<String> joinByCode({
    required String joinCode,
    required int studentUserId,
  }) async {
    final response = await http.post(
      Uri.parse(ApiConfig.joinClassByCodeUrl),
      headers: _headers,
      body: jsonEncode({
        'join_code': joinCode.trim(),
        'student_id': studentUserId,
      }),
    );

    final body = response.statusCode == 200 || response.statusCode == 201
        ? jsonDecode(response.body)
        : null;

    if (body == null) {
      throw ClassApiException(
        _errorFrom(response, 'Could not join with that code.'),
      );
    }

    return body['message']?.toString() ?? 'Joined class.';
  }

  /// Joins from an invitation link's token.
  static Future<String> joinByLink({
    required String inviteToken,
    required int studentUserId,
  }) async {
    final response = await http.post(
      Uri.parse(ApiConfig.joinClassByLinkUrl),
      headers: _headers,
      body: jsonEncode({
        'invite_token': inviteToken.trim(),
        'student_id': studentUserId,
      }),
    );

    final body = response.statusCode == 200 || response.statusCode == 201
        ? jsonDecode(response.body)
        : null;

    if (body == null) {
      throw ClassApiException(
        _errorFrom(response, 'That invitation link is not valid.'),
      );
    }

    return body['message']?.toString() ?? 'Joined class.';
  }

  /// Shows class details for an invite token before the student commits.
  static Future<Map<String, dynamic>> previewInvite(String token) async {
    final response = await http.get(
      Uri.parse(ApiConfig.invitePreviewUrl(token)),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ClassApiException(
        _errorFrom(response, 'That invitation is no longer valid.'),
      );
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Classes the student is enrolled in.
  static Future<List<Map<String, dynamic>>> fetchStudentClasses(
    int studentUserId,
  ) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.myClassesUrl}?student_id=$studentUserId'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ClassApiException(
        _errorFrom(response, 'Failed to load your classes.'),
      );
    }

    final List<dynamic> data = jsonDecode(response.body);
    return data.cast<Map<String, dynamic>>();
  }

  /// Leaves the student's current class, freeing them to join another one.
  static Future<String> leaveClass({
    required int studentUserId,
    required int classId,
  }) async {
    final response = await http.post(
      Uri.parse(ApiConfig.myClassesLeaveUrl),
      headers: _headers,
      body: jsonEncode({
        'student_id': studentUserId,
        'class_id': classId,
      }),
    );

    if (response.statusCode != 200) {
      throw ClassApiException(_errorFrom(response, 'Could not leave the class.'));
    }

    return jsonDecode(response.body)['message']?.toString() ?? 'Left the class.';
  }
}
