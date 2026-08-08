class ApiConfig {
  static String get baseUrl {
    const override = String.fromEnvironment('API_BASE_URL');
    if (override.isNotEmpty) {
      return override;
    }

    // Replace your old local IP with your ngrok HTTPS URL:
    return 'https://endpoint-chooser-finally.ngrok-free.dev'; 
  }

  static String get loginUrl => '$baseUrl/api/login/';
  static String get resetPasswordUrl => '$baseUrl/api/password-reset/';
  static String get attendanceCheckInUrl => '$baseUrl/api/attendance/check-in/';
  static String get attendanceLogsUrl => '$baseUrl/api/attendance/logs/';
  static String get currentSessionUrl => '$baseUrl/api/attendance/session/current/';

  /// Latest session limited to the classes this student actually joined.
  static String currentSessionForStudentUrl(int studentUserId, {int? classId}) {
    final classFilter = classId != null ? '&class_group_id=$classId' : '';
    return '$baseUrl/api/attendance/session/current/?student_id=$studentUserId$classFilter';
  }
  // ---------------------------------------------------------------
  // Presence verification (random "are you still there?" checks)
  // ---------------------------------------------------------------

  /// Live attendance state: pending presence check, warnings, check-out gate.
  static String presenceStatusUrl(int studentUserId, {int? sessionId}) {
    final sessionFilter = sessionId != null ? '&session_id=$sessionId' : '';
    return '$baseUrl/api/attendance/presence/status/'
        '?student_id=$studentUserId$sessionFilter';
  }

  /// Student confirms they are still on site.
  static String get presenceRespondUrl =>
      '$baseUrl/api/attendance/presence/respond/';

  /// Time-out photo. Refused when presence verification failed.
  static String get attendanceCheckOutUrl =>
      '$baseUrl/api/attendance/check-out/';

  /// Instructor releases the time-out window for a whole session.
  static String get openCheckOutUrl =>
      '$baseUrl/api/attendance/check-out/open/';

  /// Live headcount roster: standby / verified / timed-out plus ping tallies.
  static String sessionRosterUrl(int sessionId) =>
      '$baseUrl/api/attendance/session/roster/?session_id=$sessionId';

  static String get systemSettingsUrl => '$baseUrl/api/system-settings/';
  static String get usersUrl => '$baseUrl/api/users/';

  // ---------------------------------------------------------------
  // Class groups (Google Classroom style invites)
  // ---------------------------------------------------------------

  /// List an instructor's classes / create a new class.
  static String get classesUrl => '$baseUrl/api/classes/';

  /// Single class with its full member roster.
  static String classDetailUrl(int classId) => '$baseUrl/api/classes/$classId/';

  /// Generates a brand new join code, invalidating the previous one.
  static String rotateJoinCodeUrl(int classId) =>
      '$baseUrl/api/classes/$classId/rotate-code/';

  /// Student joins by typing the class code manually.
  static String get joinClassByCodeUrl => '$baseUrl/api/classes/join/';

  /// Student joins from a tapped invitation link.
  static String get joinClassByLinkUrl => '$baseUrl/api/classes/join-link/';

  /// Public preview of an invitation before committing to join.
  static String invitePreviewUrl(String token) =>
      '$baseUrl/api/classes/invite/$token/';

  /// Approve or remove a single enrollment.
  static String enrollmentUrl(int enrollmentId) =>
      '$baseUrl/api/enrollments/$enrollmentId/';

  /// Classes the signed-in student belongs to.
  static String get myClassesUrl => '$baseUrl/api/my-classes/';

  /// Every session the student was expected at, attended or not.
  static String myAttendanceHistoryUrl(int studentUserId) =>
      '$baseUrl/api/attendance/my-history/?student_id=$studentUserId';

  // ---------------------------------------------------------------
  // Director oversight
  // ---------------------------------------------------------------

  /// Campus-wide overview: all classes, instructors, and health metrics.
  /// Optional filters: `?component=CWTS`, `?instructor_id=<id>`.
  static String directorOverviewUrl({String? component, int? instructorId}) {
    final params = <String>[];
    if (component != null) params.add('component=$component');
    if (instructorId != null) params.add('instructor_id=$instructorId');
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    return '$baseUrl/api/director/overview/$query';
  }

  /// Session-by-session breakdown for one class.
  static String directorClassSessionsUrl(int classId) =>
      '$baseUrl/api/director/classes/$classId/sessions/';

  // ---------------------------------------------------------------
  // Class attendance record (instructor: per class, per calendar date)
  // ---------------------------------------------------------------

  /// Which calendar dates this class actually held activities on.
  static String classAttendanceDatesUrl(int classId) =>
      '$baseUrl/api/classes/$classId/attendance-dates/';

  /// Attendance rows for a class. Pass [date] as YYYY-MM-DD to narrow it to
  /// one day, and [asCsv] to get the same rows back as a downloadable file.
  ///
  /// The CSV flag is `export`, not `format`: DRF reserves `format` for content
  /// negotiation and would 404 before the view ever runs.
  static String classAttendanceRecordsUrl(
    int classId, {
    String? date,
    bool asCsv = false,
  }) {
    final params = <String>[];
    if (date != null && date.isNotEmpty) params.add('date=$date');
    if (asCsv) params.add('export=csv');
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    return '$baseUrl/api/classes/$classId/attendance-records/$query';
  }

  // ---------------------------------------------------------------
  // Excuse letters
  // ---------------------------------------------------------------

  /// Student files an excuse (POST) or lists the ones they have filed (GET).
  static String get excusesUrl => '$baseUrl/api/excuses/';

  /// The excuses this student has already filed, so the app can show the
  /// status of a letter instead of offering to submit a duplicate.
  static String myExcusesUrl(int studentUserId, {int? sessionId}) {
    final sessionFilter = sessionId != null ? '&session_id=$sessionId' : '';
    return '$baseUrl/api/excuses/?student_id=$studentUserId$sessionFilter';
  }

  /// The instructor's review queue. Defaults to pending; pass `all`,
  /// `approved`, or `rejected` for [status].
  static String excuseReviewQueueUrl(
    int instructorId, {
    String status = 'pending',
    int? classId,
  }) {
    final classFilter = classId != null ? '&class_id=$classId' : '';
    return '$baseUrl/api/excuses/review-queue/'
        '?instructor_id=$instructorId&status=$status$classFilter';
  }

  /// Instructor approves or rejects one excuse.
  static String reviewExcuseUrl(int excuseId) =>
      '$baseUrl/api/excuses/$excuseId/review/';
}


