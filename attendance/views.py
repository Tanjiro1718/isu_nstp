import random
from django.shortcuts import render
from rest_framework.views import APIView
from rest_framework.response import Response
from django.contrib.auth import authenticate
from django.core.mail import EmailMultiAlternatives
from django.conf import settings
from .models import (
    User,
    AttendanceSession,
    AttendanceRecord,
    StudentProfile,
    SystemSettings,
    ClassGroup,
    ClassEnrollment,
    PresenceCheck,
)
from .serializers import (
    UserSerializer,
    AttendanceLogSerializer,
    SessionSerializer,
    SystemSettingsSerializer,
    ClassGroupSerializer,
    ClassGroupDetailSerializer,
    ClassMemberSerializer,
)

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
from .fcm_utils import send_approval_notification, notify_check_out_open
from .presence import dispatch_due_presence_checks
from rest_framework.permissions import IsAuthenticated

User = get_user_model()


def generate_otp():
    """Helper function to generate a random 6-digit OTP code."""
    return str(random.randint(100000, 999999))

class RegisterView(APIView):
    permission_classes = [AllowAny]
    parser_classes = (MultiPartParser, FormParser)

    def post(self, request, *args, **kwargs):
        # 1. Grab all fields sent from Flutter
        username = request.data.get('username', '').strip()
        email = request.data.get('email', '').strip().lower()
        password = request.data.get('password')
        id_picture_front = request.FILES.get('id_picture_front')

        # Grab the student's real name
        first_name = request.data.get('first_name', '').strip()
        middle_name = request.data.get('middle_name', '').strip()
        last_name = request.data.get('last_name', '').strip()

        # Grab profile fields
        id_number = request.data.get('id_number', '').strip()
        course = request.data.get('course', '').strip()
        section = request.data.get('section', '').strip()
        course_and_section = request.data.get('course_and_section', '').strip()
        
        # 🔑 EXTRACT THE FCM DEVICE TOKEN
        fcm_token = request.data.get('fcm_token', '').strip()

        # Fallback
        if not username and id_number:
            username = id_number
            
        student_id_val = id_number or username

        # --- Basic Validation ---
        if not email or not email.endswith('@isu.edu.ph'):
            return Response({'detail': 'Only @isu.edu.ph email addresses are allowed.'}, status=status.HTTP_400_BAD_REQUEST)
            
        if User.objects.filter(email=email).exists():
            return Response({'detail': 'An account with this email already exists.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            with transaction.atomic():
                # 1. SAVE THE USER 
                user = User.objects.create(
                    username=username,
                    email=email,
                    first_name=first_name,
                    middle_name=middle_name,
                    last_name=last_name,
                    is_active=False 
                )
                user.set_password(password)
                user.save()

                # 2. SAVE THE STUDENT PROFILE (Now saving fcm_token!)
                StudentProfile.objects.create(
                    user=user,
                    student_id=student_id_val,
                    component=course,
                    section_code=section,
                    course_and_section=course_and_section or f"{course} {section}".strip(),
                    id_picture_front=id_picture_front,
                    fcm_token=fcm_token  # 👈 SAVED HERE NOW
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
    permission_classes = [AllowAny]

    # PATCH /api/users/<id>/ -> Approve User
    def patch(self, request, pk):
        # 🔍 ADD THIS DEBUG PRINT AT THE VERY TOP
        print(f"\n🔍 DEBUG PATCH REQUEST DATA: {request.data}")

        try:
            user = User.objects.get(pk=pk)

            # Safely parse boolean
            raw_is_active = request.data.get('is_active', False)
            print(f"🔍 DEBUG RAW is_active: {raw_is_active} (Type: {type(raw_is_active)})")

            if isinstance(raw_is_active, bool):
                is_active = raw_is_active
            else:
                is_active = str(raw_is_active).strip().lower() in ['true', '1', 'yes', 't']

            print(f"🔍 DEBUG PARSED is_active: {is_active}")

            user.is_active = is_active
            user.save()

            # Retrieve FCM token if profile exists
            profile = (
                getattr(user, 'student_profile', None) or 
                getattr(user, 'studentprofile', None) or 
                getattr(user, 'profile', None)
            )
            fcm_token = getattr(profile, 'fcm_token', None) if profile else None
            print(f"🔍 DEBUG USER EMAIL: {user.email} | FCM TOKEN: {fcm_token}")

            if is_active:
                # A. Send Push Notification (FCM)
                if fcm_token:
                    try:
                        send_approval_notification(fcm_token, is_approved=True, username=user.username)
                        print("✅ FCM Notification Sent!")
                    except Exception as fcm_err:
                        print(f"❌ FCM failed: {fcm_err}")
                else:
                    print("⚠️ FCM Skipped: No fcm_token found for this user.")

                # B. Send Email Notification
                if user.email:
                    subject = "Account Approved - ISU NSTP Dashboard"
                    text_content = (
                        f"Hello {user.username},\n\n"
                        f"Great news! Your account registration for the ISU NSTP Dashboard has been approved. "
                        f"You can now log into the app using your credentials.\n\n"
                        f"Thank you!"
                    )
                    try:
                        msg = EmailMultiAlternatives(
                            subject, 
                            text_content, 
                            getattr(settings, 'DEFAULT_FROM_EMAIL'), 
                            [user.email]
                        )
                        msg.send()
                        print(f"✅ Approval email sent to {user.email}")
                    except Exception as email_err:
                        print(f"❌ Failed to send approval email to {user.email}: {email_err}")
                else:
                    print("⚠️ Email Skipped: User has no email address.")

            return Response({'message': f'User status updated to is_active={is_active}'}, status=status.HTTP_200_OK)

        except User.DoesNotExist:
            return Response({'error': 'User not found'}, status=status.HTTP_404_NOT_FOUND)

    # DELETE /api/users/<id>/ -> Reject & Delete User
    def delete(self, request, pk):
        try:
            user = User.objects.get(pk=pk)

            # Retrieve FCM token before deleting user
            profile = (
                getattr(user, 'student_profile', None) or 
                getattr(user, 'studentprofile', None) or 
                getattr(user, 'profile', None)
            )
            fcm_token = getattr(profile, 'fcm_token', None) if profile else None

            # A. Send Push Notification (FCM)
            if fcm_token:
                try:
                    send_approval_notification(fcm_token, is_approved=False, username=user.username)
                except Exception as fcm_err:
                    print(f"⚠️ FCM failed: {fcm_err}")

            # B. Send Rejection Email Notification (Sent BEFORE deleting from database)
            if user.email:
                subject = "Registration Request Status - ISU NSTP Dashboard"
                text_content = (
                    f"Hello {user.username},\n\n"
                    f"We regret to inform you that your registration request for the ISU NSTP Dashboard "
                    f"was declined by the administrator.\n\n"
                    f"If you believe this was a mistake, please contact your instructor or the NSTP office."
                )
                try:
                    msg = EmailMultiAlternatives(
                        subject, 
                        text_content, 
                        getattr(settings, 'DEFAULT_FROM_EMAIL'), 
                        [user.email]
                    )
                    msg.send()
                    print(f"✅ Rejection email sent to {user.email}")
                except Exception as email_err:
                    print(f"❌ Failed to send rejection email to {user.email}: {email_err}")

            # Delete the user after sending notification
            user.delete()
            return Response({'message': 'User rejected and removed from database.'}, status=status.HTTP_200_OK)

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
            
            # A session tied to a class is only open to that class's active
            # members, otherwise anyone could post a session_id and check in.
            if session.class_group_id:
                is_enrolled = ClassEnrollment.objects.filter(
                    class_group_id=session.class_group_id,
                    student=student_profile,
                    status='active',
                ).exists()
                if not is_enrolled:
                    return Response({
                        "status": "failed",
                        "message": "You are not an approved member of this class.",
                    }, status=403)

            # One time-in per student per session.
            if AttendanceRecord.objects.filter(
                session=session, student=student_profile
            ).exists():
                return Response({
                    "status": "failed",
                    "message": "You have already timed in for this activity.",
                }, status=400)

            # The selfie must be submitted inside the session's photo window.
            now = timezone.now()
            if now > session.photo_deadline:
                late_by = int((now - session.photo_deadline).total_seconds() // 60)
                return Response({
                    "status": "failed",
                    "message": (
                        f"The {session.photo_window_minutes}-minute photo window has closed "
                        f"({late_by} min late). Ask your instructor to record you manually."
                    ),
                    "window_expired": True,
                }, status=400)

            # Calculate distance between student and session center point
            session_coords = (session.target_latitude, session.target_longitude)
            student_coords = (stud_lat, stud_lng)
            distance = geodesic(session_coords, student_coords).meters
            
            if distance <= session.radius_meters:
                selfie_file = request.FILES.get('selfie')
                mode = request.data.get('mode') or ('online' if selfie_file else 'offline')
                # Creates the record in your database
                record = AttendanceRecord.objects.create(
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

                # Queue the random "are you still there?" prompts for this student.
                checks = record.schedule_presence_checks()

                return Response({
                    "status": "success", 
                    "message": f"Attendance recorded successfully! You are {distance:.1f}m away.",
                    "record_id": record.id,
                    "presence_checks_scheduled": len(checks),
                    "presence_note": (
                        f"Stay on site. You will get {len(checks)} random presence "
                        f"check(s), roughly every 20-40 minutes, and must respond "
                        f"within {session.presence_response_minutes} minutes each."
                    ) if checks else "",
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


class PresenceStatusAPIView(APIView):
    """
    What the student's app polls while an activity is running.

    Reports the live attendance record, whether a presence check is currently
    waiting for an answer, and whether check-out is still allowed.
    """
    permission_classes = [AllowAny]

    def get(self, request):
        student_id = request.query_params.get('student_id')
        session_id = request.query_params.get('session_id')

        if not student_id:
            return Response({'error': 'student_id is required'}, status=400)

        try:
            profile = StudentProfile.objects.get(user_id=student_id)
        except StudentProfile.DoesNotExist:
            return Response({'error': 'Student not found'}, status=404)

        # Make sure any due ping is dispatched before we answer.
        dispatch_due_presence_checks(force=True)

        records = AttendanceRecord.objects.filter(student=profile)
        if session_id:
            records = records.filter(session_id=session_id)

        record = records.select_related('session').order_by('-timestamp').first()
        if record is None:
            return Response({'has_record': False}, status=200)

        pending = record.presence_checks.filter(status='sent').order_by('-sent_at').first()
        open_check = pending if (pending and pending.is_open) else None

        return Response({
            'has_record': True,
            'record_id': record.id,
            'session_id': record.session_id,
            'session_title': record.session.title,
            'presence_status': record.presence_status,
            'missed_checks': record.missed_checks,
            # Both gates must be open: presence verified AND the instructor
            # released the time-out window.
            'can_check_out': record.can_check_out and record.session.is_check_out_open,
            'check_out_open': record.session.is_check_out_open,
            'checked_out': record.check_out_at is not None,
            'total_checks': record.presence_checks.count(),
            'responded_checks': record.presence_checks.filter(status='responded').count(),
            'pending_check': {
                'check_id': open_check.id,
                'sequence': open_check.sequence,
                'expires_at': open_check.expires_at.isoformat(),
                'seconds_remaining': open_check.seconds_remaining(),
            } if open_check else None,
        })


class RespondPresenceCheckAPIView(APIView):
    """Student taps 'I'm still here' - must be inside the geofence to count."""
    permission_classes = [AllowAny]

    def post(self, request):
        check_id = request.data.get('check_id')
        student_id = request.data.get('student_id')

        if not check_id or not student_id:
            return Response({'error': 'check_id and student_id are required'}, status=400)

        try:
            check = PresenceCheck.objects.select_related(
                'record__session', 'record__student__user'
            ).get(id=check_id)
        except PresenceCheck.DoesNotExist:
            return Response({'error': 'Presence check not found'}, status=404)

        # Only the owner of the record may answer it.
        if str(check.record.student.user_id) != str(student_id):
            return Response({'error': 'This presence check is not yours.'}, status=403)

        if check.status == 'responded':
            return Response({'message': 'Already confirmed.', 'status': 'responded'})

        if check.status == 'missed' or not check.is_open:
            return Response({
                'error': 'This presence check has expired.',
                'status': 'missed',
                'presence_status': check.record.presence_status,
            }, status=400)

        # Verify they are still standing inside the geofence.
        session = check.record.session
        try:
            lat = float(request.data.get('latitude'))
            lng = float(request.data.get('longitude'))
        except (TypeError, ValueError):
            return Response({'error': 'Valid latitude and longitude are required'}, status=400)

        distance = geodesic(
            (session.target_latitude, session.target_longitude), (lat, lng)
        ).meters

        if distance > session.radius_meters:
            return Response({
                'error': (
                    f'You appear to have left the area ({distance:.0f}m away, '
                    f'limit {session.radius_meters}m). Return to the site and try again.'
                ),
                'distance_meters': round(distance, 1),
            }, status=400)

        check.status = 'responded'
        check.responded_at = timezone.now()
        check.response_latitude = lat
        check.response_longitude = lng
        check.save(update_fields=[
            'status', 'responded_at', 'response_latitude', 'response_longitude'
        ])

        return Response({
            'message': 'Presence confirmed. Thank you!',
            'status': 'responded',
            'presence_status': check.record.presence_status,
            'distance_meters': round(distance, 1),
        })


class CheckOutAPIView(APIView):
    """
    Time-out photo at the end of the activity.

    Blocked outright for students whose presence verification failed - that is
    the consequence of ignoring the random checks.
    """
    permission_classes = [AllowAny]
    parser_classes = (MultiPartParser, FormParser)

    def post(self, request):
        record_id = request.data.get('record_id')
        student_id = request.data.get('student_id')

        if not record_id or not student_id:
            return Response({'error': 'record_id and student_id are required'}, status=400)

        try:
            record = AttendanceRecord.objects.select_related(
                'session', 'student__user'
            ).get(id=record_id)
        except AttendanceRecord.DoesNotExist:
            return Response({'error': 'Attendance record not found'}, status=404)

        if str(record.student.user_id) != str(student_id):
            return Response({'error': 'This attendance record is not yours.'}, status=403)

        # Settle any check that expired while they were walking over.
        dispatch_due_presence_checks(force=True)
        record.refresh_from_db()

        if record.presence_status == 'failed':
            return Response({
                'error': (
                    'Check-out denied. You did not respond to the presence checks '
                    'during this activity. Please contact your instructor.'
                ),
                'presence_status': 'failed',
                'missed_checks': record.missed_checks,
            }, status=403)

        if record.check_out_at is not None:
            return Response({'error': 'You have already checked out.'}, status=400)

        # Students stay on standby until the instructor opens the window.
        if not record.session.is_check_out_open:
            return Response({
                'error': (
                    'Time-out is not open yet. Please wait for your instructor '
                    'to open it.'
                ),
                'check_out_open': False,
            }, status=409)

        try:
            lat = float(request.data.get('latitude'))
            lng = float(request.data.get('longitude'))
        except (TypeError, ValueError):
            return Response({'error': 'Valid latitude and longitude are required'}, status=400)

        session = record.session
        distance = geodesic(
            (session.target_latitude, session.target_longitude), (lat, lng)
        ).meters

        if distance > session.radius_meters:
            return Response({
                'error': (
                    f'You must be at the activity site to check out '
                    f'({distance:.0f}m away, limit {session.radius_meters}m).'
                ),
                'distance_meters': round(distance, 1),
            }, status=400)

        record.check_out_at = timezone.now()
        record.check_out_latitude = lat
        record.check_out_longitude = lng
        selfie = request.FILES.get('selfie')
        if selfie:
            record.check_out_selfie = selfie
        record.save(update_fields=[
            'check_out_at', 'check_out_latitude', 'check_out_longitude', 'check_out_selfie'
        ])

        # Any still-scheduled pings are pointless once they have left.
        record.presence_checks.filter(status='pending').update(status='missed')

        return Response({
            'message': 'Checked out successfully. Your attendance is complete.',
            'checked_out_at': record.check_out_at.isoformat(),
            'presence_status': record.presence_status,
        })


class OpenCheckOutAPIView(APIView):
    """
    Instructor releases the time-out window for a whole session.

    Until this is called, every student who timed in sits on standby. Only the
    instructor who owns the session may open it.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        session_id = request.data.get('session_id')
        instructor_id = request.data.get('instructor_id')

        if not session_id or not instructor_id:
            return Response(
                {'error': 'session_id and instructor_id are required'}, status=400
            )

        try:
            session = AttendanceSession.objects.get(id=session_id)
        except AttendanceSession.DoesNotExist:
            return Response({'error': 'Session not found'}, status=404)

        if str(session.instructor_id) != str(instructor_id):
            return Response(
                {'error': 'Only the instructor who owns this session can open time-out.'},
                status=403,
            )

        if session.is_check_out_open:
            return Response({
                'message': 'Time-out is already open.',
                'is_check_out_open': True,
                'opened_at': session.check_out_opened_at.isoformat()
                if session.check_out_opened_at else None,
            })

        # Settle anything that expired before we decide who is eligible.
        dispatch_due_presence_checks(force=True)

        session.is_check_out_open = True
        session.check_out_opened_at = timezone.now()
        session.save(update_fields=['is_check_out_open', 'check_out_opened_at'])

        # Only ping students who can actually act on it.
        eligible = list(
            AttendanceRecord.objects.filter(
                session=session, check_out_at__isnull=True
            ).exclude(presence_status='failed').select_related('student')
        )
        notified = notify_check_out_open(session, eligible)

        return Response({
            'message': f'Time-out opened. {notified} student(s) notified.',
            'is_check_out_open': True,
            'opened_at': session.check_out_opened_at.isoformat(),
            'notified': notified,
            'eligible': len(eligible),
        })


class SessionPresenceRosterAPIView(APIView):
    """
    Live roster for Monitor Headcounts: who is on standby, who answered their
    random presence pings, and who already timed out.
    """
    permission_classes = [AllowAny]

    def get(self, request):
        session_id = request.query_params.get('session_id')
        if not session_id:
            return Response({'error': 'session_id is required'}, status=400)

        try:
            session = AttendanceSession.objects.get(id=session_id)
        except AttendanceSession.DoesNotExist:
            return Response({'error': 'Session not found'}, status=404)

        # Keep the tallies honest before reporting them.
        dispatch_due_presence_checks(force=True)

        records = AttendanceRecord.objects.filter(
            session=session
        ).select_related('student__user').prefetch_related('presence_checks')

        students = []
        counts = {'standby': 0, 'checked_out': 0, 'warned': 0, 'failed': 0}

        for record in records:
            checks = list(record.presence_checks.all())
            responded = sum(1 for c in checks if c.status == 'responded')
            missed = sum(1 for c in checks if c.status == 'missed')
            awaiting = sum(1 for c in checks if c.status == 'sent')

            if record.check_out_at is not None:
                state = 'checked_out'
            elif record.presence_status == 'failed':
                state = 'failed'
            else:
                state = 'standby'
            counts[state] += 1
            if record.presence_status == 'warned' and state == 'standby':
                counts['warned'] += 1

            user = record.student.user
            students.append({
                'record_id': record.id,
                'student_id': record.student.student_id,
                'student_name': user.get_full_name() or user.username,
                'time_in': timezone.localtime(record.timestamp).strftime('%I:%M %p'),
                'time_out': timezone.localtime(record.check_out_at).strftime('%I:%M %p')
                if record.check_out_at else None,
                'state': state,
                'presence_status': record.presence_status,
                # "pushed a total of N random checks" - the instructor's headline number.
                'checks_total': len(checks),
                'checks_responded': responded,
                'checks_missed': missed,
                'checks_awaiting': awaiting,
                'missed_checks': record.missed_checks,
            })

        return Response({
            'session_id': session.id,
            'session_title': session.title,
            'is_check_out_open': session.is_check_out_open,
            'check_out_opened_at': session.check_out_opened_at.isoformat()
            if session.check_out_opened_at else None,
            'presence_check_count': session.presence_check_count,
            'total_timed_in': len(students),
            'counts': counts,
            'students': students,
        })


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
        sessions = AttendanceSession.objects.order_by('-date_time', '-id')

        # When a student asks, only surface sessions for classes they actually
        # joined. Without this every student sees every instructor's session.
        student_id = request.query_params.get('student_id')
        if student_id:
            try:
                profile = StudentProfile.objects.get(user_id=student_id)
            except StudentProfile.DoesNotExist:
                return Response({"message": "Student not found"}, status=404)

            class_ids = ClassEnrollment.objects.filter(
                student=profile, status='active'
            ).values_list('class_group_id', flat=True)

            if not class_ids:
                return Response(
                    {"message": "You have not joined any class yet. Ask your instructor for a class code."},
                    status=404,
                )

            sessions = sessions.filter(class_group_id__in=list(class_ids))

        # Optionally narrow to a single class (e.g. student tapped one class).
        class_group_id = request.query_params.get('class_group_id')
        if class_group_id:
            sessions = sessions.filter(class_group_id=class_group_id)

        session = sessions.first()
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

        # The geofence must belong to one of the instructor's own classes.
        class_group_id = data.get('class_group')
        if class_group_id:
            if not ClassGroup.objects.filter(
                id=class_group_id, instructor_id=instructor_id
            ).exists():
                return Response(
                    {"message": "That class does not belong to you."}, status=400
                )

        serializer = SessionSerializer(data=data)
        if serializer.is_valid():
            serializer.save()
            return Response(serializer.data, status=201)
        return Response(serializer.errors, status=400)


class UserViewSet(viewsets.ModelViewSet):
    serializer_class = UserSerializer

    def get_queryset(self):
        queryset = User.objects.all().order_by('-date_joined')
        
        is_active = self.request.query_params.get('is_active')
        if is_active == 'true':
            return queryset.filter(is_active=True)
        elif is_active == 'false':
            return queryset.filter(is_active=False)

        role = self.request.query_params.get('role')
        if role:
            queryset = queryset.filter(role=role)
            
        return queryset

    # 🔑 TRIGGERED WHEN ADMIN APPROVES (PATCH /api/users/<id>/)
    def perform_update(self, serializer):
        # 1. Get user state BEFORE update
        instance = self.get_object()
        was_active = instance.is_active

        # 2. Save update
        updated_user = serializer.save()

        # 3. If user was changed from inactive -> active, send notifications!
        if not was_active and updated_user.is_active:
            print(f"\n🎉 [APPROVAL DETECTED] Processing approval for: {updated_user.username}")

            # Retrieve FCM Token
            profile = (
                getattr(updated_user, 'student_profile', None) or 
                getattr(updated_user, 'studentprofile', None) or 
                getattr(updated_user, 'profile', None)
            )
            fcm_token = getattr(profile, 'fcm_token', None) if profile else None

            # A. Send Push Notification
            if fcm_token:
                try:
                    send_approval_notification(fcm_token, is_approved=True, username=updated_user.username)
                    print(f"✅ FCM Push Notification sent to {updated_user.username}")
                except Exception as fcm_err:
                    print(f"❌ FCM Notification failed: {fcm_err}")
            else:
                print("⚠️ FCM Skipped: Student has no fcm_token saved in profile.")

            # B. Send Email Notification
            if updated_user.email:
                subject = "Account Approved - ISU NSTP Dashboard"
                text_content = (
                    f"Hello {updated_user.username},\n\n"
                    f"Great news! Your account registration for the ISU NSTP Dashboard has been approved. "
                    f"You can now log into the app using your credentials.\n\n"
                    f"Thank you!"
                )
                try:
                    msg = EmailMultiAlternatives(
                        subject, 
                        text_content, 
                        getattr(settings, 'DEFAULT_FROM_EMAIL'), 
                        [updated_user.email]
                    )
                    msg.send()
                    print(f"✅ Approval Email successfully sent to {updated_user.email}")
                except Exception as email_err:
                    print(f"❌ Approval Email failed to send: {email_err}")

    # 🔑 TRIGGERED WHEN ADMIN REJECTS (DELETE /api/users/<id>/)
    def perform_destroy(self, instance):
        print(f"\n❌ [REJECTION DETECTED] Processing rejection for: {instance.username}")

        # Retrieve FCM Token before user is deleted
        profile = (
            getattr(instance, 'student_profile', None) or 
            getattr(instance, 'studentprofile', None) or 
            getattr(instance, 'profile', None)
        )
        fcm_token = getattr(profile, 'fcm_token', None) if profile else None

        # A. Send Push Notification
        if fcm_token:
            try:
                send_approval_notification(fcm_token, is_approved=False, username=instance.username)
                print(f"✅ Rejection Push Notification sent to {instance.username}")
            except Exception as fcm_err:
                print(f"❌ FCM Notification failed: {fcm_err}")

        # B. Send Rejection Email
        if instance.email:
            subject = "Registration Request Status - ISU NSTP Dashboard"
            text_content = (
                f"Hello {instance.username},\n\n"
                f"We regret to inform you that your registration request for the ISU NSTP Dashboard "
                f"was declined by the administrator.\n\n"
                f"If you believe this was a mistake, please contact your instructor or the NSTP office."
            )
            try:
                msg = EmailMultiAlternatives(
                    subject, 
                    text_content, 
                    getattr(settings, 'DEFAULT_FROM_EMAIL'), 
                    [instance.email]
                )
                msg.send()
                print(f"✅ Rejection Email successfully sent to {instance.email}")
            except Exception as email_err:
                print(f"❌ Rejection Email failed to send: {email_err}")

        # Delete from database
        instance.delete()

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


# ====================================================================================
# CLASS GROUP MANAGEMENT (Google Classroom Style)
# ====================================================================================

class ClassGroupListCreateAPIView(APIView):
    """List all classes for an instructor, or create a new class."""
    permission_classes = [AllowAny]

    def get(self, request):
        instructor_id = request.query_params.get('instructor_id')
        if not instructor_id:
            return Response({'error': 'instructor_id is required'}, status=400)

        classes = ClassGroup.objects.filter(instructor_id=instructor_id)
        serializer = ClassGroupSerializer(classes, many=True, context={'request': request})
        return Response(serializer.data)

    def post(self, request):
        serializer = ClassGroupSerializer(data=request.data, context={'request': request})
        if serializer.is_valid():
            serializer.save()
            return Response(serializer.data, status=201)
        return Response(serializer.errors, status=400)


class ClassGroupDetailAPIView(APIView):
    """Get, update, or delete a single class with full member roster."""
    permission_classes = [AllowAny]

    def get(self, request, pk):
        try:
            class_group = ClassGroup.objects.get(pk=pk)
            serializer = ClassGroupDetailSerializer(class_group, context={'request': request})
            return Response(serializer.data)
        except ClassGroup.DoesNotExist:
            return Response({'error': 'Class not found'}, status=404)

    def patch(self, request, pk):
        try:
            class_group = ClassGroup.objects.get(pk=pk)
            serializer = ClassGroupSerializer(class_group, data=request.data, partial=True, context={'request': request})
            if serializer.is_valid():
                serializer.save()
                return Response(serializer.data)
            return Response(serializer.errors, status=400)
        except ClassGroup.DoesNotExist:
            return Response({'error': 'Class not found'}, status=404)

    def delete(self, request, pk):
        try:
            class_group = ClassGroup.objects.get(pk=pk)
            class_group.delete()
            return Response({'message': 'Class deleted successfully'}, status=200)
        except ClassGroup.DoesNotExist:
            return Response({'error': 'Class not found'}, status=404)


class RotateJoinCodeAPIView(APIView):
    """Generate a new join code for a class (invalidates the old one)."""
    permission_classes = [AllowAny]

    def post(self, request, pk):
        try:
            class_group = ClassGroup.objects.get(pk=pk)
            new_code = class_group.rotate_join_code()
            return Response({'join_code': new_code, 'message': 'Join code rotated successfully'})
        except ClassGroup.DoesNotExist:
            return Response({'error': 'Class not found'}, status=404)


class JoinClassByCodeAPIView(APIView):
    """Student joins a class by entering the join code."""
    permission_classes = [AllowAny]

    def post(self, request):
        # Codes are shown to students in upper case but stored lower case, and
        # people paste them with stray spaces/dashes - normalise all of that.
        raw_code = str(request.data.get('join_code') or '')
        join_code = raw_code.strip().replace(' ', '').replace('-', '')
        student_id = request.data.get('student_id')  # User ID

        if not join_code or not student_id:
            return Response({'error': 'join_code and student_id are required'}, status=400)

        # Case-insensitive lookup so "K4MQ7ZX" and "k4mq7zx" both work.
        class_group = ClassGroup.objects.filter(join_code__iexact=join_code).first()
        if class_group is None:
            return Response({'error': 'Invalid join code. Please check with your instructor.'}, status=404)

        if not class_group.is_join_enabled:
            return Response({'error': 'This class is not accepting new members'}, status=403)

        try:
            student_user = User.objects.get(id=student_id)
        except User.DoesNotExist:
            return Response({'error': 'Student account not found'}, status=404)

        # Older accounts (and any created before the profile signal existed) may
        # not have a StudentProfile yet. Create one instead of hard failing.
        student_profile, _ = StudentProfile.objects.get_or_create(
            user=student_user,
            defaults={
                'student_id': f'{student_user.username}-{student_user.id}',
                'component': '',
                'section_code': '',
            },
        )

        # Check if already enrolled
        existing = ClassEnrollment.objects.filter(
            class_group=class_group,
            student=student_profile
        ).first()

        if existing:
            if existing.status == 'removed':
                existing.status = 'pending' if class_group.requires_approval else 'active'
                existing.save()
                return Response({'message': 'Re-enrolled in class', 'status': existing.status})
            return Response({'message': 'Already enrolled in this class', 'status': existing.status})

        # Create new enrollment
        enrollment_status = 'pending' if class_group.requires_approval else 'active'
        ClassEnrollment.objects.create(
            class_group=class_group,
            student=student_profile,
            status=enrollment_status,
            join_method='code'
        )

        return Response({
            'message': 'Successfully joined class' if enrollment_status == 'active' else 'Join request submitted for approval',
            'status': enrollment_status,
            'class_name': class_group.name
        }, status=201)


class JoinClassByLinkAPIView(APIView):
    """Student joins by clicking the invitation link (uses invite_token)."""
    permission_classes = [AllowAny]

    def post(self, request):
        invite_token = request.data.get('invite_token', '').strip()
        student_id = request.data.get('student_id')

        if not invite_token or not student_id:
            return Response({'error': 'invite_token and student_id are required'}, status=400)

        try:
            class_group = ClassGroup.objects.get(invite_token=invite_token)
        except ClassGroup.DoesNotExist:
            return Response({'error': 'Invalid invitation link'}, status=404)

        if not class_group.is_join_enabled:
            return Response({'error': 'This class is not accepting new members'}, status=403)

        try:
            student_user = User.objects.get(id=student_id)
            student_profile = StudentProfile.objects.get(user=student_user)
        except (User.DoesNotExist, StudentProfile.DoesNotExist):
            return Response({'error': 'Student not found'}, status=404)

        existing = ClassEnrollment.objects.filter(
            class_group=class_group,
            student=student_profile
        ).first()

        if existing:
            if existing.status == 'removed':
                existing.status = 'pending' if class_group.requires_approval else 'active'
                existing.save()
                return Response({'message': 'Re-enrolled in class', 'status': existing.status})
            return Response({'message': 'Already enrolled in this class', 'status': existing.status})

        enrollment_status = 'pending' if class_group.requires_approval else 'active'
        ClassEnrollment.objects.create(
            class_group=class_group,
            student=student_profile,
            status=enrollment_status,
            join_method='link'
        )

        return Response({
            'message': 'Successfully joined class' if enrollment_status == 'active' else 'Join request submitted for approval',
            'status': enrollment_status,
            'class_name': class_group.name
        }, status=201)


class ClassEnrollmentDetailAPIView(APIView):
    """Instructor approves a pending member or removes an existing one."""
    permission_classes = [AllowAny]

    def patch(self, request, pk):
        """Approve / change status of a pending enrollment."""
        new_status = (request.data.get('status') or 'active').strip().lower()
        valid = dict(ClassEnrollment.STATUS_CHOICES)
        if new_status not in valid:
            return Response({'error': f'status must be one of {list(valid)}'}, status=400)

        try:
            enrollment = ClassEnrollment.objects.select_related('student__user').get(pk=pk)
        except ClassEnrollment.DoesNotExist:
            return Response({'error': 'Enrollment not found'}, status=404)

        enrollment.status = new_status
        enrollment.save(update_fields=['status'])
        return Response(ClassMemberSerializer(enrollment).data)

    def delete(self, request, pk):
        """Remove a student from the class (soft delete keeps the audit trail)."""
        try:
            enrollment = ClassEnrollment.objects.get(pk=pk)
        except ClassEnrollment.DoesNotExist:
            return Response({'error': 'Enrollment not found'}, status=404)

        enrollment.status = 'removed'
        enrollment.save(update_fields=['status'])
        return Response({'message': 'Student removed from class'}, status=200)


class InvitePreviewAPIView(APIView):
    """
    Public lookup so the app can show 'Join CWTS 1 - Sat AM?' before the student commits.
    Deliberately exposes only non-sensitive class info.
    """
    permission_classes = [AllowAny]

    def get(self, request, token):
        try:
            class_group = ClassGroup.objects.select_related('instructor').get(invite_token=token)
        except ClassGroup.DoesNotExist:
            return Response({'error': 'This invitation link is not valid or has been revoked.'}, status=404)

        return Response({
            'id': class_group.id,
            'name': class_group.name,
            'component': class_group.component,
            'section_code': class_group.section_code,
            'description': class_group.description,
            'instructor_name': class_group.instructor.get_full_name() or class_group.instructor.username,
            'is_join_enabled': class_group.is_join_enabled,
            'requires_approval': class_group.requires_approval,
            'student_count': class_group.student_count,
            'invite_token': class_group.invite_token,
        })


def invite_landing_page(request, token):
    """
    Plain HTML page a student lands on when they tap the shared link on a phone.
    It shows the class + join code so they can finish joining inside the app.
    """
    class_group = ClassGroup.objects.filter(invite_token=token).select_related('instructor').first()

    if not class_group:
        return render(request, 'attendance/invite_invalid.html', status=404)

    return render(request, 'attendance/invite_landing.html', {
        'class_group': class_group,
        'instructor_name': class_group.instructor.get_full_name() or class_group.instructor.username,
    })


class StudentClassListAPIView(APIView):
    """List all classes a student is enrolled in."""

    permission_classes = [AllowAny]

    def get(self, request):
        student_id = request.query_params.get('student_id')  # User ID
        if not student_id:
            return Response({'error': 'student_id is required'}, status=400)

        try:
            student_user = User.objects.get(id=student_id)
            student_profile = StudentProfile.objects.get(user=student_user)
        except (User.DoesNotExist, StudentProfile.DoesNotExist):
            return Response({'error': 'Student not found'}, status=404)

        enrollments = ClassEnrollment.objects.filter(
            student=student_profile
        ).exclude(status='removed').select_related('class_group__instructor')

        classes_data = []
        for enrollment in enrollments:
            class_group = enrollment.class_group
            classes_data.append({
                'id': class_group.id,
                'name': class_group.name,
                'component': class_group.component,
                'section_code': class_group.section_code,
                'description': class_group.description,
                'instructor_name': class_group.instructor.get_full_name() or class_group.instructor.username,
                'enrollment_status': enrollment.status,
                'joined_at': enrollment.joined_at.strftime('%m/%d/%Y'),
                'student_count': class_group.student_count,
            })

        return Response(classes_data)


