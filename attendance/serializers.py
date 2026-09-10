from rest_framework import serializers
from django.contrib.auth.hashers import make_password
from .models import (
    User,
    AttendanceSession,
    AttendanceRecord,
    AttendanceExcuse,
    GeofenceLeaveRequest,
    StudentProfile,
    InstructorProfile,
    SystemSettings,
    ClassGroup,
    ClassEnrollment,
)
from django.contrib.auth import get_user_model
from .models import StudentProfile


User = get_user_model()

class RegisterSerializer(serializers.ModelSerializer):
    # Support common field name keys from the frontend
    id_number = serializers.CharField(write_only=True, required=False, allow_blank=True)
    student_id = serializers.CharField(write_only=True, required=False, allow_blank=True)
    course = serializers.CharField(write_only=True, required=False, allow_blank=True)
    component = serializers.CharField(write_only=True, required=False, allow_blank=True)
    section = serializers.CharField(write_only=True, required=False, allow_blank=True)
    section_code = serializers.CharField(write_only=True, required=False, allow_blank=True)

    class Meta:
        model = User
        fields = [
            'username', 'email', 'password', 
            'id_number', 'student_id', 
            'course', 'component', 
            'section', 'section_code'
        ]

    def create(self, validated_data):
        # Extract profile fields with fallbacks for alternative key names
        student_id_val = validated_data.pop('student_id', None) or validated_data.pop('id_number', None)
        component_val = validated_data.pop('component', None) or validated_data.pop('course', None)
        section_code_val = validated_data.pop('section_code', None) or validated_data.pop('section', None)

        user = User.objects.create_user(...)

        # Fetch the profile created by the signal and update its fields
        StudentProfile.objects.update_or_create(
            user=user,
            defaults={
                'student_id': student_id,
                'course_and_section': course_and_section,
                'component': component,
                'section_code': section_code,
                'id_picture_front': id_picture_front,
            }
        )

class UserSerializer(serializers.ModelSerializer):
    email = serializers.EmailField(required=False, allow_blank=True)
    # Writable: the admin's "Add New User" screen posts this, and an instructor
    # or director account is useless if the role is silently dropped and the
    # model default ('student') wins. Display still goes through _display_role
    # so legacy rows with a blank role keep resolving sensibly.
    role = serializers.ChoiceField(
        choices=User.ROLE_CHOICES, required=False
    )
    id_picture_front = serializers.SerializerMethodField()
    student_id = serializers.CharField(required=False, write_only=True, allow_blank=True, allow_null=True)
    course_and_section = serializers.CharField(required=False, write_only=True, allow_blank=True, allow_null=True)

    class Meta:
        model = User
        fields = [
            'id',
            'username',
            'email',
            'role',
            'student_id',
            'course_and_section',
            'password',
            'is_active',
            'id_picture_front',
        ]
        extra_kwargs = {'password': {'write_only': True}}

    def to_representation(self, instance):
        rep = super().to_representation(instance)
        rep['role'] = self._display_role(instance)
        profile = self._get_student_profile(instance)

        # Expose every field captured at registration so the app can show a
        # complete profile without extra round trips.
        rep['student_id'] = profile.student_id if profile else None
        rep['course_and_section'] = profile.course_and_section if profile else None
        rep['component'] = profile.component if profile else None
        rep['section_code'] = profile.section_code if profile else None
        rep['is_email_verified'] = profile.is_email_verified if profile else False
        rep['is_approved_by_admin'] = profile.is_approved_by_admin if profile else False
        rep['phone_number'] = getattr(instance, 'phone_number', None)
        rep['department'] = self._get_instructor_department(instance)
        rep['first_name'] = instance.first_name
        rep['middle_name'] = getattr(instance, 'middle_name', None)
        rep['last_name'] = instance.last_name
        rep['date_joined'] = instance.date_joined.isoformat() if instance.date_joined else None

        return rep

    def _get_student_profile(self, obj):
        return (
            getattr(obj, 'student_profile', None) or 
            getattr(obj, 'studentprofile', None) or 
            getattr(obj, 'profile', None)
        )

    def _get_instructor_department(self, obj):
        """Department (ROTC/CWTS/LTS) for instructor accounts, else None."""
        profile = getattr(obj, 'instructor_profile', None) or getattr(obj, 'instructorprofile', None)
        if profile is None:
            return None
        department = getattr(profile, 'department', None)
        return str(department) if department else None

    def _display_role(self, obj):
        """
        Role the app should route on.

        Falls back to 'admin' for superusers created before the role field was
        populated, so they don't get dropped onto the student dashboard.
        """
        if getattr(obj, 'role', None):
            return str(obj.role).lower()
        if getattr(obj, 'is_superuser', False) or getattr(obj, 'is_staff', False):
            return 'admin'
        return 'student'

    def get_id_picture_front(self, obj):
        image_field = None
        profile = self._get_student_profile(obj)
        
        if profile:
            image_field = getattr(profile, 'id_picture_front', None) or getattr(profile, 'id_picture', None) or getattr(profile, 'id_proof', None)

        if not image_field:
            pending = getattr(obj, 'pendingapproval', None) or getattr(obj, 'pending_approval', None)
            if not pending and hasattr(obj, 'pendingapproval_set') and obj.pendingapproval_set.exists():
                pending = obj.pendingapproval_set.first()
            if pending:
                image_field = getattr(pending, 'id_picture_front', None) or getattr(pending, 'id_picture', None)

        if image_field and hasattr(image_field, 'url'):
            try:
                request = self.context.get('request')
                if request is not None:
                    return request.build_absolute_uri(image_field.url)
                return image_field.url
            except Exception:
                return None
        return None

    def create(self, validated_data):
        student_id = validated_data.pop('student_id', None)
        course_and_section = validated_data.pop('course_and_section', None)

        if 'password' in validated_data:
            validated_data['password'] = make_password(validated_data['password'])
            
        validated_data['is_active'] = True
        
        if validated_data.get('role') == 'admin':
            validated_data['is_staff'] = True
            validated_data['is_superuser'] = True
            
        user = super().create(validated_data)

        if user.role == 'student':
            StudentProfile.objects.create(
                user=user,
                student_id=student_id or f'{user.username}-{user.id}',
                component=course_and_section or 'N/A', # Save exactly what was typed here
                section_code='' # Leave blank since it is merged
            )

        return user

    def update(self, instance, validated_data):
        password = validated_data.pop('password', None)
        student_id = validated_data.pop('student_id', None)
        course_and_section = validated_data.pop('course_and_section', None)

        if password:
            instance.password = make_password(password)

        for attr, value in validated_data.items():
            setattr(instance, attr, value)

        instance.save()

        if instance.role == 'student' and any(v is not None for v in (student_id, course_and_section)):
            profile, _ = StudentProfile.objects.get_or_create(
                user=instance,
                defaults={
                    'student_id': student_id or f'{instance.username}-{instance.id}',
                    'component': course_and_section or 'N/A',
                    'section_code': '',
                },
            )
            if student_id is not None: profile.student_id = student_id
            if course_and_section is not None: profile.component = course_and_section
            profile.save()

        return instance


class SessionSerializer(serializers.ModelSerializer):
    class_name = serializers.SerializerMethodField()

    class Meta:
        model = AttendanceSession
        fields = '__all__'
        # Every activity is a fixed 4 hours. The instructor's form doesn't ask
        # for it, and marking it read-only means a hand-crafted request can't
        # stretch the window either - the presence schedule depends on it.
        #
        # The two alert stamps are the server's own bookkeeping: they are what
        # stops a reminder going out twice. A client that could set them would
        # be able to silence an activity's notifications before they ever fire.
        read_only_fields = [
            'duration_minutes',
            'reminder_sent_at',
            'start_notified_at',
        ]

    def validate_reminder_minutes(self, value):
        """
        Keep the lead time sane: 0 means 'no advance warning', and anything
        beyond a day is almost certainly a typo (e.g. minutes typed as hours).
        """
        if value < 0:
            raise serializers.ValidationError("Reminder minutes cannot be negative.")
        if value > 1440:
            raise serializers.ValidationError(
                "Reminder cannot be more than 24 hours (1440 minutes) ahead."
            )
        return value

    def get_class_name(self, obj):
        return obj.class_group.name if obj.class_group else None

class AttendanceLogSerializer(serializers.ModelSerializer):
    student_id = serializers.CharField(source='student.student_id', read_only=True)
    student_name = serializers.SerializerMethodField()
    department = serializers.CharField(source='student.component', read_only=True)
    section_code = serializers.CharField(source='student.section_code', read_only=True)
    session_title = serializers.CharField(source='session.title', read_only=True)
    # Lets the instructor's monitor screen group rows by activity and open the
    # matching live roster.
    session_id = serializers.IntegerField(read_only=True)
    session_check_out_open = serializers.BooleanField(
        source='session.is_check_out_open', read_only=True
    )
    date = serializers.DateTimeField(source='timestamp', format='%m/%d/%Y', read_only=True)
    time = serializers.DateTimeField(source='timestamp', format='%I:%M %p', read_only=True)
    mode = serializers.CharField(read_only=True)
    student_photo_url = serializers.SerializerMethodField()
    address = serializers.CharField(source='student_address', allow_blank=True, allow_null=True, read_only=True)
    selfie_image_url = serializers.SerializerMethodField()
    # Blank until the student submits their time-out photo.
    check_out_time = serializers.DateTimeField(
        source='check_out_at', format='%I:%M %p', read_only=True
    )

    class Meta:
        model = AttendanceRecord
        fields = [
            'id',
            'student_id',
            'student_name',
            'department',
            'section_code',
            'session_title',
            'session_id',
            'session_check_out_open',
            'date',
            'time',
            'mode',
            'status',
            'student_latitude',
            'student_longitude',
            'address',
            'selfie_verified',
            'face_similarity',
            'student_photo_url',
            'selfie_image_url',
            'presence_status',
            'missed_checks',
            'check_out_time',
        ]

    def get_student_name(self, obj):
        user = obj.student.user
        full_name = user.get_full_name()
        return full_name or user.username

    def get_selfie_image_url(self, obj):
        if not obj.selfie_image:
            return None

        request = self.context.get('request')
        image_url = obj.selfie_image.url
        if request is not None:
            return request.build_absolute_uri(image_url)
        return image_url

    def get_student_photo_url(self, obj):
        return self.get_selfie_image_url(obj)

class SystemSettingsSerializer(serializers.ModelSerializer):
    class Meta:
        model = SystemSettings
        fields = '__all__'


class ClassMemberSerializer(serializers.ModelSerializer):
    """A single student inside a class roster."""
    enrollment_id = serializers.IntegerField(source='id', read_only=True)
    user_id = serializers.IntegerField(source='student.user.id', read_only=True)
    student_id = serializers.CharField(source='student.student_id', read_only=True)
    student_name = serializers.SerializerMethodField()
    email = serializers.EmailField(source='student.user.email', read_only=True)
    course_and_section = serializers.CharField(source='student.course_and_section', read_only=True)
    joined_at = serializers.DateTimeField(format='%m/%d/%Y %I:%M %p', read_only=True)

    class Meta:
        model = ClassEnrollment
        fields = [
            'enrollment_id',
            'user_id',
            'student_id',
            'student_name',
            'email',
            'course_and_section',
            'status',
            'join_method',
            'joined_at',
        ]

    def get_student_name(self, obj):
        user = obj.student.user
        return user.get_full_name() or user.username


class ClassGroupSerializer(serializers.ModelSerializer):
    instructor_name = serializers.SerializerMethodField()
    student_count = serializers.IntegerField(read_only=True)
    pending_count = serializers.SerializerMethodField()
    invite_link = serializers.SerializerMethodField()
    created_at = serializers.DateTimeField(format='%m/%d/%Y', read_only=True)

    class Meta:
        model = ClassGroup
        fields = [
            'id',
            'name',
            'component',
            'section_code',
            'description',
            'instructor',
            'instructor_name',
            'join_code',
            'invite_link',
            'is_join_enabled',
            'requires_approval',
            'student_count',
            'pending_count',
            'created_at',
        ]
        read_only_fields = ['join_code', 'invite_link', 'created_at']

    def get_instructor_name(self, obj):
        return obj.instructor.get_full_name() or obj.instructor.username

    def get_pending_count(self, obj):
        return obj.enrollments.filter(status='pending').count()

    def get_invite_link(self, obj):
        path = f'/join/{obj.invite_token}/'
        request = self.context.get('request')
        if request is not None:
            return request.build_absolute_uri(path)
        return path


class ClassGroupDetailSerializer(ClassGroupSerializer):
    members = serializers.SerializerMethodField()

    class Meta(ClassGroupSerializer.Meta):
        fields = ClassGroupSerializer.Meta.fields + ['members']

    def get_members(self, obj):
        enrollments = obj.enrollments.exclude(status='removed').select_related('student__user')
        return ClassMemberSerializer(enrollments, many=True).data


class AttendanceExcuseSerializer(serializers.ModelSerializer):
    """
    One excuse letter, shaped for both the student's own list and the
    instructor's review queue.

    Everything the instructor decides (`status`, `response_note`, who reviewed
    it and when) is read-only here - those are set by the review endpoint, so a
    student cannot approve their own excuse by posting the field.
    """

    student_name = serializers.SerializerMethodField()
    student_number = serializers.CharField(source='student.student_id', read_only=True)
    session_title = serializers.CharField(source='session.title', read_only=True)
    session_date = serializers.DateTimeField(
        source='session.date_time', format='%m/%d/%Y', read_only=True
    )
    class_name = serializers.SerializerMethodField()
    kind_label = serializers.CharField(source='get_kind_display', read_only=True)
    attachment_url = serializers.SerializerMethodField()
    submitted_at = serializers.DateTimeField(format='%m/%d/%Y %I:%M %p', read_only=True)
    reviewed_at = serializers.DateTimeField(
        format='%m/%d/%Y %I:%M %p', read_only=True
    )
    reviewed_by_name = serializers.SerializerMethodField()

    class Meta:
        model = AttendanceExcuse
        fields = [
            'id',
            'session',
            'session_title',
            'session_date',
            'class_name',
            'student_name',
            'student_number',
            'kind',
            'kind_label',
            'reason',
            'attachment_url',
            'status',
            'response_note',
            'submitted_at',
            'reviewed_at',
            'reviewed_by_name',
        ]
        read_only_fields = [
            'status',
            'response_note',
            'submitted_at',
            'reviewed_at',
            'reviewed_by_name',
        ]

    def get_student_name(self, obj):
        user = obj.student.user
        return user.get_full_name() or user.username

    def get_class_name(self, obj):
        group = obj.session.class_group
        return group.name if group else None

    def get_reviewed_by_name(self, obj):
        if not obj.reviewed_by:
            return None
        return obj.reviewed_by.get_full_name() or obj.reviewed_by.username

    def get_attachment_url(self, obj):
        if not obj.attachment:
            return None
        request = self.context.get('request')
        if request is not None:
            return request.build_absolute_uri(obj.attachment.url)
        return obj.attachment.url


class GeofenceLeaveRequestSerializer(serializers.ModelSerializer):
    """
    A student's temporary leave request, used on both the student's own list
    and the instructor's pending-leave queue.
    """

    student_name = serializers.SerializerMethodField()
    student_number = serializers.CharField(source='student.student_id', read_only=True)
    session_title = serializers.CharField(source='session.title', read_only=True)
    session_date = serializers.DateTimeField(
        source='session.date_time', format='%m/%d/%Y %I:%M %p', read_only=True
    )
    requested_at = serializers.DateTimeField(
        format='%I:%M %p', read_only=True
    )
    reviewed_at = serializers.DateTimeField(
        format='%I:%M %p', read_only=True
    )
    reviewed_by_name = serializers.SerializerMethodField()
    seconds_remaining = serializers.IntegerField(read_only=True)
    deadline = serializers.DateTimeField(format='%I:%M %p', read_only=True)

    class Meta:
        model = GeofenceLeaveRequest
        fields = [
            'id',
            'session',
            'session_title',
            'session_date',
            'student_name',
            'student_number',
            'reason',
            'requested_at',
            'deadline',
            'status',
            'seconds_remaining',
            'response_note',
            'reviewed_at',
            'reviewed_by_name',
            'returned_at',
            'return_latitude',
            'return_longitude',
        ]
        read_only_fields = [
            'status',
            'response_note',
            'requested_at',
            'deadline',
            'reviewed_at',
            'reviewed_by_name',
            'returned_at',
            'return_latitude',
            'return_longitude',
        ]

    def get_student_name(self, obj):
        user = obj.student.user
        return user.get_full_name() or user.username

    def get_reviewed_by_name(self, obj):
        if not obj.reviewed_by:
            return None
        return obj.reviewed_by.get_full_name() or obj.reviewed_by.username


class EditProfileSerializer(serializers.ModelSerializer):
    """
    Self-service profile edits for staff roles (instructor, director, admin).

    Students are deliberately excluded - the API view gates on role before this
    serializer ever runs. Username is the app's identity key (student id, login,
    class matches) so it stays immutable here.
    """
    first_name = serializers.CharField(
        required=False, allow_blank=True, max_length=150
    )
    middle_name = serializers.CharField(
        required=False, allow_blank=True, allow_null=True, max_length=150
    )
    last_name = serializers.CharField(
        required=False, allow_blank=True, max_length=150
    )
    email = serializers.EmailField(required=False, allow_blank=True)
    phone_number = serializers.CharField(
        required=False, allow_blank=True, allow_null=True, max_length=15
    )
    department = serializers.CharField(
        required=False, allow_blank=True, allow_null=True, max_length=50
    )

    class Meta:
        model = User
        fields = [
            'id',
            'username',
            'first_name',
            'middle_name',
            'last_name',
            'email',
            'phone_number',
            'department',
        ]
        read_only_fields = ['id', 'username']

    def update(self, instance, validated_data):
        instance.email = (validated_data.get('email') or instance.email).strip()
        instance.first_name = (validated_data.get('first_name') or instance.first_name).strip()
        instance.last_name = (validated_data.get('last_name') or instance.last_name).strip()

        if 'middle_name' in validated_data:
            value = (validated_data.get('middle_name') or '').strip()
            instance.middle_name = value or None

        if 'phone_number' in validated_data:
            instance.phone_number = (validated_data.get('phone_number') or '').strip()

        instance.save()

        # Instructors carry a department (ROTC / CWTS / LTS). Deliberately
        # skipped for other roles so a director never gets an InstructorProfile.
        department = (validated_data.get('department') or '').strip()
        if department and (instance.role or '').lower() == 'instructor':
            profile, _ = InstructorProfile.objects.get_or_create(user=instance)
            profile.department = department
            profile.save()

        return instance

