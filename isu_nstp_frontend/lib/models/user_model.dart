class UserModel {
  final int id;
  final String username;
  final String email;
  final String role;
  final String? studentId;
  final String? courseAndSection;
  final String? token;

  // Remaining details captured at registration, shown on the profile screen.
  final String? component;
  final String? sectionCode;
  final String? firstName;
  final String? middleName;
  final String? lastName;
  final String? phoneNumber;
  final String? department;
  final String? idPictureUrl;
  final String? dateJoined;
  final bool isEmailVerified;
  final bool isApprovedByAdmin;

  UserModel({
    required this.id,
    required this.username,
    required this.email,
    this.role = 'student',
    this.studentId,
    this.courseAndSection,
    this.token,
    this.component,
    this.sectionCode,
    this.firstName,
    this.middleName,
    this.lastName,
    this.phoneNumber,
    this.department,
    this.idPictureUrl,
    this.dateJoined,
    this.isEmailVerified = false,
    this.isApprovedByAdmin = false,
  });

  /// Full name when the user supplied one, otherwise the username.
  String get displayName {
    final parts = [firstName, middleName, lastName]
        .where((p) => p != null && p.trim().isNotEmpty)
        .map((p) => p!.trim());
    return parts.isEmpty ? username : parts.join(' ');
  }

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

    bool asBool(dynamic v) =>
        v == true || v == 1 || v?.toString().toLowerCase() == 'true';

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
      component: json['component']?.toString(),
      sectionCode: json['section_code']?.toString(),
      firstName: json['first_name']?.toString(),
      middleName: json['middle_name']?.toString(),
      lastName: json['last_name']?.toString(),
      phoneNumber: json['phone_number']?.toString(),
      department: json['department']?.toString(),
      idPictureUrl: json['id_picture_front']?.toString(),
      dateJoined: json['date_joined']?.toString(),
      isEmailVerified: asBool(json['is_email_verified']),
      isApprovedByAdmin: asBool(json['is_approved_by_admin']),
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
      'component': component,
      'section_code': sectionCode,
      'first_name': firstName,
      'middle_name': middleName,
      'last_name': lastName,
      'phone_number': phoneNumber,
      'department': department,
      'id_picture_front': idPictureUrl,
      'date_joined': dateJoined,
      'is_email_verified': isEmailVerified,
      'is_approved_by_admin': isApprovedByAdmin,
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
    String? component,
    String? sectionCode,
    String? firstName,
    String? middleName,
    String? lastName,
    String? phoneNumber,
    String? department,
    String? idPictureUrl,
    String? dateJoined,
    bool? isEmailVerified,
    bool? isApprovedByAdmin,
  }) {
    return UserModel(
      id: id ?? this.id,
      username: username ?? this.username,
      email: email ?? this.email,
      role: role ?? this.role,
      studentId: studentId ?? this.studentId,
      courseAndSection: courseAndSection ?? this.courseAndSection,
      token: token ?? this.token,
      component: component ?? this.component,
      sectionCode: sectionCode ?? this.sectionCode,
      firstName: firstName ?? this.firstName,
      middleName: middleName ?? this.middleName,
      lastName: lastName ?? this.lastName,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      department: department ?? this.department,
      idPictureUrl: idPictureUrl ?? this.idPictureUrl,
      dateJoined: dateJoined ?? this.dateJoined,
      isEmailVerified: isEmailVerified ?? this.isEmailVerified,
      isApprovedByAdmin: isApprovedByAdmin ?? this.isApprovedByAdmin,
    );
  }
}