class UserModel {
  final int id;
  final String username;
  final String email;
  final String role;
  final String? studentId;
  final String? course;
  final String? section;
  final String? token;

  UserModel({
    required this.id,
    required this.username,
    required this.email,
    this.role = 'student',
    this.studentId,
    this.course,
    this.section,
    this.token,
  });

  /// Factory constructor with full null-safety and dynamic type parsing
  factory UserModel.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return UserModel(
        id: 0,
        username: '',
        email: '',
        role: 'student',
      );
    }

    return UserModel(
      // Safely parse ID whether backend sends String or int
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      username: json['username']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      role: json['role']?.toString() ?? 'student',
      
      // Flexible key lookups for varying Django response formats
      studentId: (json['student_id'] ?? json['studentId'])?.toString(),
      course: (json['course'] ?? json['department'] ?? json['course_and_section'])?.toString(),
      section: (json['section'] ?? json['section_code'])?.toString(),
      token: json['token']?.toString(),
    );
  }

  /// Converts model instance to a JSON Map (Useful for SharedPreferences)
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'role': role,
      'student_id': studentId,
      'course': course,
      'section': section,
      'token': token,
    };
  }

  /// Creates a clone with updated values for state updates
  UserModel copyWith({
    int? id,
    String? username,
    String? email,
    String? role,
    String? studentId,
    String? course,
    String? section,
    String? token,
  }) {
    return UserModel(
      id: id ?? this.id,
      username: username ?? this.username,
      email: email ?? this.email,
      role: role ?? this.role,
      studentId: studentId ?? this.studentId,
      course: course ?? this.course,
      section: section ?? this.section,
      token: token ?? this.token,
    );
  }
}