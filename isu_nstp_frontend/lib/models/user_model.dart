class UserModel {
  final int id;
  final String username;
  final String email;
  final String role;
  final String campus;
  final String? studentId;
  final String? course;
  final String? section;

  UserModel({
    required this.id,
    required this.username,
    required this.email,
    required this.role,
    required this.campus,
    this.studentId,
    this.course,
    this.section,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'],
      username: json['username'] ?? '',
      email: json['email'] ?? '',
      role: json['role'] ?? 'student',
      campus: json['campus'],
      studentId: json['student_id']?.toString(),
      course: (json['course'] ?? json['department'])?.toString(),
      section: (json['section'] ?? json['section_code'])?.toString(),
    );
  }
}