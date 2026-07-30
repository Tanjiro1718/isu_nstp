from rest_framework import serializers
from django.contrib.auth.hashers import make_password
from .models import User, AttendanceSession, AttendanceRecord, StudentProfile, SystemSettings

class RegisterSerializer(serializers.ModelSerializer):
    course_and_section = serializers.CharField(required=True)

    class Meta:
        model = StudentProfile
        fields = ['username', 'email', 'password', 'course_and_section', 'id_picture_front']

    def create(self, validated_data):
        course_and_section = validated_data.pop('course_and_section')
        # Implementation hidden for brevity...
        pass

class UserSerializer(serializers.ModelSerializer):
    email = serializers.EmailField(required=False, allow_blank=True)
    student_id = serializers.SerializerMethodField()
    course = serializers.SerializerMethodField()
    section = serializers.SerializerMethodField()
    id_picture_front = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = [
            'id',
            'username',
            'email',
            'role',
            'campus',
            'student_id',
            'course',
            'section',
            'password',
            'is_active',
            'id_picture_front',
        ]
        extra_kwargs = {'password': {'write_only': True}}

    def create(self, validated_data):
        if 'password' in validated_data:
            validated_data['password'] = make_password(validated_data['password'])
            
        validated_data['is_active'] = True
        
        if validated_data.get('role') == 'admin':
            validated_data['is_staff'] = True
            validated_data['is_superuser'] = True
            
        return super().create(validated_data)

    def update(self, instance, validated_data):
        password = validated_data.pop('password', None)
        student_id = validated_data.pop('student_id', None)
        course = validated_data.pop('course', validated_data.pop('department', None))
        section = validated_data.pop('section', validated_data.pop('section_code', None))

        if password:
            instance.password = make_password(password)

        for attr, value in validated_data.items():
            setattr(instance, attr, value)

        instance.save()

        if instance.role == 'student' and any(
            value is not None for value in (student_id, course, section)
        ):
            profile, _ = StudentProfile.objects.get_or_create(
                user=instance,
                defaults={
                    'student_id': student_id or f'{instance.username}-{instance.id}',
                    'component': course or 'CWTS',
                    'section_code': section or 'CWTS-1A',
                },
            )

            if student_id is not None:
                profile.student_id = student_id
            if course is not None:
                profile.component = course
            if section is not None:
                profile.section_code = section
            profile.save()

        return instance

    def validate_email(self, value):
        if value and not value.lower().endswith('@isu.edu.ph'):
            raise serializers.ValidationError('Email must end with @isu.edu.ph')
        return value

    def get_student_id(self, obj):
        profile = getattr(obj, 'studentprofile', None) or getattr(obj, 'profile', None)
        return profile.student_id if profile else None

    def get_course(self, obj):
        profile = getattr(obj, 'studentprofile', None) or getattr(obj, 'profile', None)
        return profile.component if profile else None

    def get_section(self, obj):
        profile = getattr(obj, 'studentprofile', None) or getattr(obj, 'profile', None)
        return profile.section_code if profile else None

    # =========================================================================
    # ROBUST IMAGE URL RESOLUTION
    # =========================================================================
    def get_id_picture_front(self, obj):
        image_field = None
        
        # 1. Check all common related_name variations for StudentProfile
        profile = (
            getattr(obj, 'studentprofile', None) or 
            getattr(obj, 'student_profile', None) or 
            getattr(obj, 'profile', None)
        )
        if profile:
            image_field = (
                getattr(profile, 'id_picture_front', None) or 
                getattr(profile, 'id_picture', None) or 
                getattr(profile, 'id_proof', None)
            )

        # 2. Check all common related_name variations for PendingApproval
        if not image_field:
            pending = (
                getattr(obj, 'pendingapproval', None) or 
                getattr(obj, 'pending_approval', None)
            )
            if not pending:
                if hasattr(obj, 'pendingapproval_set') and obj.pendingapproval_set.exists():
                    pending = obj.pendingapproval_set.first()
                elif hasattr(obj, 'pending_approvals') and obj.pending_approvals.exists():
                    pending = obj.pending_approvals.first()
                    
            if pending:
                image_field = (
                    getattr(pending, 'id_picture_front', None) or 
                    getattr(pending, 'id_picture', None) or 
                    getattr(pending, 'id_proof', None)
                )

        # 3. Construct absolute URL
        if image_field and hasattr(image_field, 'url'):
            try:
                request = self.context.get('request')
                if request is not None:
                    return request.build_absolute_uri(image_field.url)
                return image_field.url
            except Exception:
                return None

        return None


class SessionSerializer(serializers.ModelSerializer):
    class Meta:
        model = AttendanceSession
        fields = '__all__'

class AttendanceLogSerializer(serializers.ModelSerializer):
    student_id = serializers.CharField(source='student.student_id', read_only=True)
    student_name = serializers.SerializerMethodField()
    department = serializers.CharField(source='student.component', read_only=True)
    section_code = serializers.CharField(source='student.section_code', read_only=True)
    session_title = serializers.CharField(source='session.title', read_only=True)
    date = serializers.DateTimeField(source='timestamp', format='%m/%d/%Y', read_only=True)
    time = serializers.DateTimeField(source='timestamp', format='%I:%M %p', read_only=True)
    mode = serializers.CharField(read_only=True)
    student_photo_url = serializers.SerializerMethodField()
    address = serializers.CharField(source='student_address', allow_blank=True, allow_null=True, read_only=True)
    selfie_image_url = serializers.SerializerMethodField()

    class Meta:
        model = AttendanceRecord
        fields = [
            'id',
            'student_id',
            'student_name',
            'department',
            'section_code',
            'session_title',
            'date',
            'time',
            'mode',
            'status',
            'student_latitude',
            'student_longitude',
            'address',
            'selfie_verified',
            'student_photo_url',
            'selfie_image_url',
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