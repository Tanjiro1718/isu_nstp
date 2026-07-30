import random
from django.shortcuts import render
from rest_framework.views import APIView
from rest_framework.response import Response
from django.contrib.auth import authenticate
from django.core.mail import EmailMultiAlternatives
from django.conf import settings
from .models import User, AttendanceSession, AttendanceRecord, StudentProfile, SystemSettings
from .serializers import UserSerializer, AttendanceLogSerializer, SessionSerializer, SystemSettingsSerializer
from rest_framework.permissions import AllowAny
from geopy.distance import geodesic
from rest_framework import viewsets
from django.contrib.auth import get_user_model
from rest_framework.parsers import MultiPartParser, FormParser
from django.core.cache import cache
from django.utils import timezone
import datetime
from .models import OTPVerification
from django.db import transaction
from rest_framework import status, views
from .fcm_utils import send_approval_notification
from rest_framework.permissions import IsAuthenticated

User = get_user_model()


def generate_otp():
    """Helper function to generate a random 6-digit OTP code."""
    return str(random.randint(100000, 999999))

class RegisterView(APIView):
    permission_classes = [AllowAny]
    parser_classes = (MultiPartParser, FormParser)

    def post(self, request, *args, **kwargs):
        # 1. Grab all possible fields the frontend might be sending
        username = request.data.get('username', '').strip()
        email = request.data.get('email', '').strip().lower()
        password = request.data.get('password')
        id_picture_front = request.FILES.get('id_picture_front')
        
        # Grab the extra profile fields
        id_number = request.data.get('id_number', '').strip()
        course = request.data.get('course', '').strip()
        section = request.data.get('section', '').strip()
        course_and_section = request.data.get('course_and_section', '').strip()

        # Fallback: If frontend only sent id_number, use it as username
        if not username and id_number:
            username = id_number
            
        student_id_val = id_number or username

        # --- Basic Validation ---
        if not email or not email.endswith('@isu.edu.ph'):
            return Response({'detail': 'Only @isu.edu.ph email addresses are allowed.'}, status=status.HTTP_400_BAD_REQUEST)
            
        if User.objects.filter(email=email).exists():
            return Response({'detail': 'An account with this email already exists.'}, status=status.HTTP_400_BAD_REQUEST)

        # 🛡️ THE SAFETY BUBBLE
        try:
            with transaction.atomic():
                # 1. SAVE THE USER 
                user = User.objects.create(
                    username=username,
                    email=email,
                    is_active=False 
                )
                user.set_password(password)
                user.save()

                # 2. SAVE THE STUDENT PROFILE (Now with all fields included!)
                StudentProfile.objects.create(
                    user=user,
                    student_id=student_id_val,  # Maps to profile.student_id
                    component=course,           # Maps to profile.component (Course)
                    section_code=section,       # Maps to profile.section_code (Section)
                    course_and_section=course_and_section or f"{course} {section}".strip(),
                    id_picture_front=id_picture_front
                )
        except Exception as e:
            print(f"\n❌ DATABASE CRASH: {str(e)}\n")
            return Response({'detail': f'Failed to save account: {str(e)}'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        # 3. GENERATE & SAVE OTP
        otp_code = generate_otp()
        OTPVerification.objects.update_or_create(
            email=email,
            defaults={'code': str(otp_code)}
        )

        print(f"\n[REGISTERED] User: {email} | OTP: {otp_code}\n")

        # 4. SEND VERIFICATION EMAIL
        subject = f"{otp_code} is your ISU verification code"
        text_content = f"Your ISU verification code is: {otp_code}."
        
        try:
            msg = EmailMultiAlternatives(subject, text_content, getattr(settings, 'DEFAULT_FROM_EMAIL'), [email])
            msg.send()
            return Response({'message': 'Registration request submitted!'}, status=status.HTTP_201_CREATED)
        except Exception as e:
            user.delete() 
            return Response({'detail': f'Failed to send email: {str(e)}'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

from django.core.cache import cache

class SendVerificationCodeAPIView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        email = request.data.get('email', '').strip().lower()

        if not email or not email.endswith('@isu.edu.ph'):
            return Response({'detail': 'Only @isu.edu.ph email addresses are allowed.'}, status=status.HTTP_403_FORBIDDEN)

        otp_code = generate_otp()

        # Save or update the code in MySQL database
        OTPVerification.objects.update_or_create(
            email=email,
            defaults={'code': str(otp_code)}
        )

        print(f"\n[SAVED TO DATABASE] Email: '{email}' | Code: '{otp_code}'\n")

        subject = f"{otp_code} is your ISU verification code"
        text_content = f"Your ISU verification code is: {otp_code}. It will expire in 10 minutes."

        try:
            msg = EmailMultiAlternatives(
                subject,
                text_content,
                getattr(settings, 'DEFAULT_FROM_EMAIL'),
                [email]
            )
            msg.attach_alternative(f"<h2>Your code is: <b>{otp_code}</b></h2>", "text/html")
            msg.send()

            return Response({'message': f'Verification code sent successfully to {email}'}, status=status.HTTP_200_OK)

        except Exception as e:
            return Response({'detail': f'Failed to deliver email: {str(e)}'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class VerifyOTPAPIView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        # 1. Print the ENTIRE raw request body received from Flutter
        print("\n================ RAW FLUTTER REQUEST DATA ================")
        print(f"REQUEST DATA: {request.data}")
        print("==========================================================\n")

        email = request.data.get('email', '').strip().lower()
        
        # Check all possible keys Flutter might be using
        submitted_code = (
            request.data.get('otp_code') or 
            request.data.get('otp') or 
            request.data.get('code') or 
            request.data.get('verification_code') or ''
        )
        submitted_code = str(submitted_code).strip()

        if not email or not submitted_code:
            print(f"❌ REJECTED: Missing fields. Email: '{email}', Code: '{submitted_code}'")
            return Response({'detail': 'Email and verification code are required.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            record = OTPVerification.objects.get(email=email)

            print(f"🔍 DB CHECK -> Expected: '{record.code}' | Received: '{submitted_code}'")

            if not record.is_valid():
                print("❌ REJECTED: Code in DB is older than 10 minutes.")
                record.delete()
                return Response({'detail': 'Verification code has expired.'}, status=status.HTTP_400_BAD_REQUEST)

            if record.code == submitted_code:
                record.delete()
                print("✅ SUCCESS: Codes matched!")
                return Response({'message': 'Code verified successfully!'}, status=status.HTTP_200_OK)
            else:
                print(f"❌ MISMATCH: App sent '{submitted_code}', but DB holds '{record.code}'")
                return Response({'detail': 'Invalid verification code.'}, status=status.HTTP_400_BAD_REQUEST)

        except OTPVerification.DoesNotExist:
            print(f"❌ REJECTED: No DB record found for '{email}'")
            return Response({'detail': 'No verification code requested for this email.'}, status=status.HTTP_400_BAD_REQUEST)

class ApproveRejectUserView(views.APIView):
    
    # PATCH /api/users/<id>/
    def patch(self, request, pk):
        try:
            user = User.objects.get(pk=pk)
            is_active = request.data.get('is_active', False)
            user.is_active = is_active
            user.save()

            # Retrieve FCM token (Checking 'student_profile' matching your model's related_name)
            profile = (
                getattr(user, 'student_profile', None) or 
                getattr(user, 'studentprofile', None) or 
                getattr(user, 'profile', None)
            )
            fcm_token = profile.fcm_token if profile else None

            if is_active and fcm_token:
                send_approval_notification(fcm_token, is_approved=True, username=user.username)

            return Response({'message': 'User approved successfully.'}, status=status.HTTP_200_OK)
        except User.DoesNotExist:
            return Response({'error': 'User not found'}, status=status.HTTP_404_NOT_FOUND)

    # DELETE /api/users/<id>/
    def delete(self, request, pk):
        try:
            user = User.objects.get(pk=pk)
            
            # Retrieve FCM token before deleting user
            profile = (
                getattr(user, 'student_profile', None) or 
                getattr(user, 'studentprofile', None) or 
                getattr(user, 'profile', None)
            )
            fcm_token = profile.fcm_token if profile else None

            # Send rejection notification
            if fcm_token:
                send_approval_notification(fcm_token, is_approved=False, username=user.username)
            
            user.delete()
            return Response({'message': 'User rejected and deleted.'}, status=status.HTTP_204_NO_CONTENT)
        except User.DoesNotExist:
            return Response({'error': 'User not found'}, status=status.HTTP_404_NOT_FOUND)

class PasswordResetAPIView(APIView):
    """
    Resets temporary password and emails it directly to the user's @isu.edu.ph inbox.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        username = request.data.get('username')
        email = request.data.get('email')

        # 1. Check if both fields were sent
        if not username or not email:
            return Response({'detail': 'Username and email are required.'}, status=status.HTTP_400_BAD_REQUEST)

        # 2. Enforce ISU Domain
        if not email.endswith('@isu.edu.ph'):
            return Response({'detail': 'Only @isu.edu.ph emails are allowed.'}, status=status.HTTP_403_FORBIDDEN)

        try:
            # 3. Find the user in the database
            user = User.objects.get(username=username, email=email)
            
            # 4. Generate temporary password
            temp_password = "ISU-" + User.objects.make_random_password(length=6)
            user.set_password(temp_password)
            user.save()

            # 5. Send notification email to Gmail inbox
            subject = f"{temp_password} is your temporary password for ISU App"
            text_content = f"Hello {username},\n\nYour temporary password is: {temp_password}\n\nPlease log in and update your password immediately."
            
            html_content = f"""
            <!DOCTYPE html>
            <html>
            <body style="font-family: Arial, sans-serif; padding: 20px;">
              <h2>Password Reset Notification</h2>
              <p>Hello <strong>{username}</strong>,</p>
              <p>Your temporary password for the ISU App has been generated:</p>
              <div style="font-size: 26px; font-weight: bold; background-color: #eef2ff; color: #1e40af; padding: 12px 20px; display: inline-block; border-radius: 6px; letter-spacing: 2px;">
                {temp_password}
              </div>
              <p>Please log in using this temporary password and update it immediately in your profile settings.</p>
            </body>
            </html>
            """

            try:
                msg = EmailMultiAlternatives(
                    subject,
                    text_content,
                    getattr(settings, 'DEFAULT_FROM_EMAIL', 'ISU Support <noreply@isu.edu.ph>'),
                    [email]
                )
                msg.attach_alternative(html_content, "text/html")
                msg.send()
            except Exception as mail_err:
                print(f"Email delivery failed: {mail_err}")

            # Print to terminal for debugging
            print(f"PASSWORD RESET SUCCESS: User {username} temporary password is: {temp_password}")

            return Response({'detail': 'Password reset successful. Check your email for your temporary password.'}, status=status.HTTP_200_OK)
            
        except User.DoesNotExist:
            return Response({'detail': 'No account found matching this username and verified email.'}, status=status.HTTP_404_NOT_FOUND)


class LoginAPIView(APIView):
    def post(self, request):
        username = request.data.get('username') or request.POST.get('username')
        password = request.data.get('password') or request.POST.get('password')

        print(f"--- Login Attempt Received ---")
        print(f"Username typed: '{username}'")
        print(f"Password typed: '{password}'")

        try:
            # 1. Fetch the user directly from your custom database table
            user = User.objects.get(username=username)
            print(f"User found in database! Hashed password: {user.password}")

            # 2. Check the password manually using Django's internal hashing comparison
            if user.check_password(password):
                print("Password verified successfully!")
                
                # Check if account is active
                if not user.is_active:
                    return Response({'message': 'Account is disabled'}, status=status.HTTP_400_BAD_REQUEST)

                # 3. Use UserSerializer to serialize the complete user data profile.
                user_data = UserSerializer(user, context={'request': request}).data

                return Response({
                    'message': 'Login successful',
                    'user': user_data  # Passes the complete serialized dictionary layout
                }, status=status.HTTP_200_OK)
            else:
                print("Password check failed.")
                return Response({'message': 'Invalid password'}, status=status.HTTP_400_BAD_REQUEST)

        except User.DoesNotExist:
            print("Username not found in the database.")
            return Response({'message': 'Username does not exist'}, status=status.HTTP_400_BAD_REQUEST)


class ProcessCheckInAPI(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        session_id = request.data.get('session_id')
        student_id = request.data.get('student_id')
        
        # Guard against empty or missing data to prevent app crashes
        if not session_id or not student_id or not request.data.get('latitude') or not request.data.get('longitude'):
            return Response({"status": "error", "message": "Missing required parameters"}, status=400)
            
        try:
            stud_lat = float(request.data.get('latitude'))
            stud_lng = float(request.data.get('longitude'))
        except (ValueError, TypeError):
            return Response({"status": "error", "message": "Invalid coordinates format"}, status=400)
        
        try:
            session = AttendanceSession.objects.get(id=session_id)
            student_user = User.objects.get(id=student_id)
            student_profile, _ = StudentProfile.objects.get_or_create(
                user=student_user,
                defaults={
                    'student_id': f'{student_user.username}-{student_user.id}',
                    'component': 'CWTS',
                    'section_code': 'CWTS-1A',
                },
            )
            
            # Calculate distance between student and session center point
            session_coords = (session.target_latitude, session.target_longitude)
            student_coords = (stud_lat, stud_lng)
            distance = geodesic(session_coords, student_coords).meters
            
            if distance <= session.radius_meters:
                selfie_file = request.FILES.get('selfie')
                mode = request.data.get('mode') or ('online' if selfie_file else 'offline')
                # Creates the record in your database
                AttendanceRecord.objects.create(
                    session=session,
                    student=student_profile,
                    student_latitude=stud_lat,
                    student_longitude=stud_lng,
                    status='Present',
                    mode=mode,
                    student_address=request.data.get('address') or request.data.get('student_address'),
                    selfie_verified=bool(selfie_file),
                    selfie_image=selfie_file,
                )
                return Response({
                    "status": "success", 
                    "message": f"Attendance recorded successfully! You are {distance:.1f}m away."
                })
            else:
                return Response({
                    "status": "failed", 
                    "message": f"Out of bounds! You are {distance:.1f}m away, but the limit is {session.radius_meters}m."
                }, status=400)
                
        except AttendanceSession.DoesNotExist:
            return Response({"status": "error", "message": "Attendance session not found"}, status=404)
        except User.DoesNotExist:
            return Response({"status": "error", "message": "Student account not found"}, status=404)


class AttendanceLogAPIView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        records = AttendanceRecord.objects.select_related(
            'student__user',
            'session',
            'session__instructor',
        ).order_by('-timestamp')

        instructor_id = request.query_params.get('instructor_id')
        if instructor_id:
            records = records.filter(session__instructor_id=instructor_id)

        serializer = AttendanceLogSerializer(records, many=True, context={'request': request})
        return Response(serializer.data)


class AttendanceSessionAPIView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        session = AttendanceSession.objects.order_by('-date_time', '-id').first()
        if not session:
            return Response({"message": "No active attendance session found"}, status=404)

        serializer = SessionSerializer(session)
        return Response(serializer.data)

    def post(self, request):
        instructor_id = request.data.get('instructor')
        if not instructor_id:
            return Response({"message": "Instructor is required"}, status=400)

        data = request.data.copy()
        data.setdefault('title', 'NSTP Attendance Session')

        serializer = SessionSerializer(data=data)
        if serializer.is_valid():
            serializer.save()
            return Response(serializer.data, status=201)
        return Response(serializer.errors, status=400)


class UserViewSet(viewsets.ModelViewSet):
    serializer_class = UserSerializer

    def get_queryset(self):
        # Start with everyone
        queryset = User.objects.all().order_by('-date_joined')
        
        # Check if Flutter is asking for a specific group
        is_active = self.request.query_params.get('is_active')
        
        if is_active == 'true':
            # Returns ONLY approved users
            return queryset.filter(is_active=True)
        elif is_active == 'false':
            # Returns ONLY pending users
            return queryset.filter(is_active=False)

        role = self.request.query_params.get('role')
        if role:
            queryset = queryset.filter(role=role)
            
        # If Flutter doesn't ask, return everyone
        return queryset


class SystemSettingsAPIView(APIView):
    def get(self, request):
        settings, created = SystemSettings.objects.get_or_create(id=1)
        serializer = SystemSettingsSerializer(settings)
        return Response(serializer.data)

    def put(self, request):
        settings, created = SystemSettings.objects.get_or_create(id=1)
        serializer = SystemSettingsSerializer(settings, data=request.data, partial=True)
        if serializer.is_valid():
            serializer.save()
            return Response(serializer.data)
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)