class ApiConfig {
  static String get baseUrl {
    const override = String.fromEnvironment('API_BASE_URL');
    if (override.isNotEmpty) {
      return override;
    }

    // Default to the LAN address used by the backend in this workspace.
    // If your backend IP changes, pass --dart-define=API_BASE_URL=http://x.x.x.x:8000
    // when running Flutter.
    return 'http://192.168.1.47:8000';
  }

  static String get loginUrl => '$baseUrl/api/login/';
  static String get resetPasswordUrl => '$baseUrl/api/password-reset/';
  static String get attendanceCheckInUrl => '$baseUrl/api/attendance/check-in/';
  static String get attendanceLogsUrl => '$baseUrl/api/attendance/logs/';
  static String get currentSessionUrl => '$baseUrl/api/attendance/session/current/';
  static String get systemSettingsUrl => '$baseUrl/api/system-settings/';
  static String get usersUrl => '$baseUrl/api/users/';
}
