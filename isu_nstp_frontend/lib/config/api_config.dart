class ApiConfig {
  static String get baseUrl {
    const override = String.fromEnvironment('API_BASE_URL');
    if (override.isNotEmpty) {
      return override;
    }

    // Replace your old local IP with your ngrok HTTPS URL:
    return 'https://endpoint-chooser-finally.ngrok-free.dev -> http://localhost:8000 '; 
  }

  static String get loginUrl => '$baseUrl/api/login/';
  static String get resetPasswordUrl => '$baseUrl/api/password-reset/';
  static String get attendanceCheckInUrl => '$baseUrl/api/attendance/check-in/';
  static String get attendanceLogsUrl => '$baseUrl/api/attendance/logs/';
  static String get currentSessionUrl => '$baseUrl/api/attendance/session/current/';
  static String get systemSettingsUrl => '$baseUrl/api/system-settings/';
  static String get usersUrl => '$baseUrl/api/users/';
}