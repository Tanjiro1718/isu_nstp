class UserModel {
  final int id;
  final String username;
  final String email;
  final String role;
  final String? studentId;
  final String? courseAndSection;
  final String? token;

  UserModel({
    required this.id,
    required this.username,
    required this.email,
    this.role = 'student',
    this.studentId,
    this.courseAndSection,
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
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      username: json['username']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      role: json['role']?.toString() ?? 'student',
      studentId: (json['student_id'] ?? json['studentId'])?.toString(),
      
      // Capture the single field from backend
      courseAndSection: json['course_and_section']?.toString(), 
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
      'course_and_section': courseAndSection,
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
    String? courseAndSection,
    String? token,
  }) {
    return UserModel(
      id: id ?? this.id,
      username: username ?? this.username,
      email: email ?? this.email,
      role: role ?? this.role,
      studentId: studentId ?? this.studentId,
      courseAndSection: courseAndSection ?? this.courseAndSection,
      token: token ?? this.token,
    );
  }
}