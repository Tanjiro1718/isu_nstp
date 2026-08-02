class ClassModel {
  final int id;
  final String name;
  final String component;
  final String sectionCode;
  final String? description;
  final String instructorName;
  final String joinCode;
  final String inviteLink;
  final bool isJoinEnabled;
  final bool requiresApproval;
  final int studentCount;
  final int pendingCount;
  final String createdAt;
  final List<ClassMember>? members;

  ClassModel({
    required this.id,
    required this.name,
    required this.component,
    required this.sectionCode,
    this.description,
    required this.instructorName,
    required this.joinCode,
    required this.inviteLink,
    required this.isJoinEnabled,
    required this.requiresApproval,
    required this.studentCount,
    required this.pendingCount,
    required this.createdAt,
    this.members,
  });

  factory ClassModel.fromJson(Map<String, dynamic> json) {
    return ClassModel(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      component: json['component'] ?? '',
      sectionCode: json['section_code'] ?? '',
      description: json['description'],
      instructorName: json['instructor_name'] ?? '',
      joinCode: json['join_code'] ?? '',
      inviteLink: json['invite_link'] ?? '',
      isJoinEnabled: json['is_join_enabled'] ?? true,
      requiresApproval: json['requires_approval'] ?? false,
      studentCount: json['student_count'] ?? 0,
      pendingCount: json['pending_count'] ?? 0,
      createdAt: json['created_at'] ?? '',
      members: json['members'] != null
          ? (json['members'] as List)
              .map((m) => ClassMember.fromJson(m))
              .toList()
          : null,
    );
  }
}

class ClassMember {
  final int enrollmentId;
  final int userId;
  final String studentId;
  final String studentName;
  final String email;
  final String courseAndSection;
  final String status;
  final String joinMethod;
  final String joinedAt;

  ClassMember({
    required this.enrollmentId,
    required this.userId,
    required this.studentId,
    required this.studentName,
    required this.email,
    required this.courseAndSection,
    required this.status,
    required this.joinMethod,
    required this.joinedAt,
  });

  factory ClassMember.fromJson(Map<String, dynamic> json) {
    return ClassMember(
      enrollmentId: json['enrollment_id'] ?? 0,
      userId: json['user_id'] ?? 0,
      studentId: json['student_id'] ?? '',
      studentName: json['student_name'] ?? '',
      email: json['email'] ?? '',
      courseAndSection: json['course_and_section'] ?? '',
      status: json['status'] ?? '',
      joinMethod: json['join_method'] ?? '',
      joinedAt: json['joined_at'] ?? '',
    );
  }
}
