from rest_framework import serializers
from django.contrib.auth.hashers import make_password
from .models import User, AttendanceSession, AttendanceRecord, StudentProfile, SystemSettings
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
    
    # Change these to CharFields to accept input during Registration/POST
    student_id = serializers.CharField(required=False, write_only=True, allow_blank=True, allow_null=True)
    course = serializers.CharField(required=False, write_only=True, allow_blank=True, allow_null=True)
    section = serializers.CharField(required=False, write_only=True, allow_blank=True, allow_null=True)

    class Meta:
        model = User
        fields = [
            'id',
            'username',
            'email',
            'role',
            'student_id',
            'course',
            'section',
            'password',
            'is_active',
            'id_picture_front',
        ]
        extra_kwargs = {'password': {'write_only': True}}

    def to_representation(self, instance):
        """Override this to manually append the read-only values to the GET response."""
        rep = super().to_representation(instance)
        
        # Resolve Profile fields
        profile = self._get_student_profile(instance)
        rep['student_id'] = profile.student_id if profile else None
        rep['course'] = profile.component if profile else None
        rep['section'] = profile.section_code if profile else None
        
        # Resolve Methods
        rep['role'] = self.get_role(instance)
        rep['id_picture_front'] = self.get_id_picture_front(instance)
        
        return rep

    def _get_student_profile(self, obj):
        """Helper to robustly fetch student profile regardless of related_name."""
        return (
            getattr(obj, 'student_profile', None) or 
            getattr(obj, 'studentprofile', None) or 
            getattr(obj, 'profile', None)
        )

    def get_role(self, obj):
        if hasattr(obj, 'role') and obj.role:
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
        # 1. Pop the registration data out so it doesn't crash the base User creation
        student_id = validated_data.pop('student_id', None)
        course = validated_data.pop('course', None)
        section = validated_data.pop('section', None)

        # 2. Handle base user fields
        if 'password' in validated_data:
            validated_data['password'] = make_password(validated_data['password'])
            
        validated_data['is_active'] = True
        
        if validated_data.get('role') == 'admin':
            validated_data['is_staff'] = True
            validated_data['is_superuser'] = True
            
        # 3. Create the User
        user = super().create(validated_data)

        # 4. IMMEDIATELY create the StudentProfile using the provided inputs
        if user.role == 'student':
            StudentProfile.objects.create(
                user=user,
                student_id=student_id or f'{user.username}-{user.id}',
                component=course or 'CWTS',
                section_code=section or 'CWTS-1A'
            )

        return user

    def update(self, instance, validated_data):
        password = validated_data.pop('password', None)
        student_id = validated_data.pop('student_id', None)
        course = validated_data.pop('course', None)
        section = validated_data.pop('section', None)

        if password:
            instance.password = make_password(password)

        for attr, value in validated_data.items():
            setattr(instance, attr, value)

        instance.save()

        # Update profile if any profile fields were sent
        if instance.role == 'student' and any(v is not None for v in (student_id, course, section)):
            profile, _ = StudentProfile.objects.get_or_create(
                user=instance,
                defaults={
                    'student_id': student_id or f'{instance.username}-{instance.id}',
                    'component': course or 'CWTS',
                    'section_code': section or 'CWTS-1A',
                },
            )
            if student_id is not None: profile.student_id = student_id
            if course is not None: profile.component = course
            if section is not None: profile.section_code = section
            profile.save()

        return instance


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