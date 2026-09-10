import csv
import random
import re
from django.http import HttpResponse
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
    AttendanceExcuse,
    GeofenceLeaveRequest,
    StudentProfile,
    SystemSettings,
    ClassGroup,
    ClassEnrollment,
    PresenceCheck,
    PasswordResetCode,
    AccountDeletionRequest,
)
from .serializers import (
    UserSerializer,
    AttendanceLogSerializer,
    AttendanceExcuseSerializer,
    GeofenceLeaveRequestSerializer,
    SessionSerializer,
    SystemSettingsSerializer,
    ClassGroupSerializer,
    ClassGroupDetailSerializer,
    ClassMemberSerializer,
    EditProfileSerializer,
)

from rest_framework.permissions import AllowAny
from geopy.distance import geodesic
from rest_framework import viewsets
from django.contrib.auth import get_user_model
from rest_framework.parsers import MultiPartParser, FormParser, JSONParser
from django.core.cache import cache
from django.db.models import Count, Max, Q
from django.utils import timezone
import datetime
from .models import OTPVerification
from django.db import transaction
from rest_framework import status, views
from .fcm_utils import (
    send_approval_notification,
    notify_check_out_open,
    send_password_reset_code,
    send_change_password_code,
    send_password_changed_alert,
    send_excuse_submitted,
    send_excuse_reviewed,
    send_leave_request_notification,
    send_leave_reviewed,
    send_check_in_notification,
)
from .presence import dispatch_due_presence_checks
from .session_alerts import dispatch_due_session_alerts
from .password_policy import password_error
from rest_framework.permissions import IsAuthenticated

User = get_user_model()

def privacy_policy(request):
    return render(request, "attendance/privacy_policy.html")

def terms_and_conditions(request):
    return render(request, "attendance/terms_and_conditions.html")

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

        # The app validates as you type, but that is only a convenience - a
        # direct POST would sail past it, so re-check here.
        pw_problem = password_error(password or '')
        if pw_problem:
            return Response(
                {'error': pw_problem},
                status=status.HTTP_400_BAD_REQUEST,
            )

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

        # New students must consent to the Privacy Policy and Terms before we
        # create the account. Mirrors the checkbox on the registration screen.
        if str(request.data.get('accept_terms', '')).strip().lower() not in ('true', '1', 'yes', 'on'):
            return Response(
                {'detail': 'You must accept the Privacy Policy and Terms & Conditions to continue.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            with transaction.atomic():
                # 1. SAVE THE USER 
                user = User.objects.create(
                    username=username,
                    email=email,
                    first_name=first_name,
                    middle_name=middle_name,
                    last_name=last_name,
                    is_active=False,
                    accepted_terms_at=timezone.now(),
                    accepted_privacy_at=timezone.now(),
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

class RequestPasswordResetCodeAPIView(APIView):
    """
    Step 1 of forgot-password: the user gives the email on their account and we
    send a 6-digit code to it, plus a push notification to their phone.

    Always answers 200 for a well-formed ISU address so the endpoint cannot be
    used to discover which emails have accounts.
    """
    permission_classes = [AllowAny]

    # Neutral reply used for both "sent" and "no such account".
    _SENT_MESSAGE = (
        'If that email is registered, a 6-digit code is on its way. '
        'Check your phone notifications and your inbox.'
    )

    def post(self, request):
        email = str(request.data.get('email') or '').strip().lower()

        if not email:
            return Response(
                {'detail': 'Email is required.'}, status=status.HTTP_400_BAD_REQUEST
            )
        if not email.endswith('@isu.edu.ph'):
            return Response(
                {'detail': 'Only @isu.edu.ph email addresses are allowed.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        user = User.objects.filter(email__iexact=email).first()
        if user is None:
            # Don't leak whether the address exists.
            print(f"⚠️ Password reset requested for unknown email: {email}")
            return Response({'message': self._SENT_MESSAGE, 'push_sent': False},
                            status=status.HTTP_200_OK)

        code = generate_otp()

        # One live code per user - issuing a new one retires the old.
        PasswordResetCode.objects.filter(user=user).delete()
        PasswordResetCode.objects.create(user=user, code=code)

        # A. Push the code to their phone (the channel the user asked for).
        profile = getattr(user, 'student_profile', None)
        fcm_token = getattr(profile, 'fcm_token', None) if profile else None
        push_sent = False
        if fcm_token:
            try:
                push_sent = send_password_reset_code(fcm_token, code, user.username)
            except Exception as fcm_err:
                print(f"❌ Password-reset push failed: {fcm_err}")
        else:
            print(f"⚠️ No FCM token for {user.username}; email only.")

        # B. Email it too, so a user without the app installed is not locked out.
        subject = f"{code} is your ISU password reset code"
        text_content = (
            f"Hello {user.username},\n\n"
            f"Your password reset code is: {code}\n\n"
            f"It expires in 10 minutes. If you did not request this, ignore this email."
        )
        html_content = f"""
        <!DOCTYPE html>
        <html>
        <body style="font-family: Arial, sans-serif; padding: 20px;">
          <h2>Password Reset Code</h2>
          <p>Hello <strong>{user.username}</strong>,</p>
          <p>Use this code to reset your ISU NSTP password:</p>
          <div style="font-size: 30px; font-weight: bold; background-color: #eef2ff;
                      color: #1e40af; padding: 14px 24px; display: inline-block;
                      border-radius: 6px; letter-spacing: 4px;">{code}</div>
          <p>This code expires in 10 minutes.</p>
          <p style="color:#666; font-size:12px;">
            If you did not request a password reset, you can safely ignore this email.
          </p>
        </body>
        </html>
        """

        email_sent = False
        try:
            msg = EmailMultiAlternatives(
                subject,
                text_content,
                getattr(settings, 'DEFAULT_FROM_EMAIL', 'ISU Support <noreply@isu.edu.ph>'),
                [user.email],
            )
            msg.attach_alternative(html_content, "text/html")
            msg.send()
            email_sent = True
        except Exception as mail_err:
            print(f"❌ Password-reset email failed: {mail_err}")

        # If neither channel worked the user can never continue - say so.
        if not push_sent and not email_sent:
            return Response(
                {'detail': 'Could not deliver your code right now. Please try again later.'},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

        print(f"🔐 Password reset code for {user.username}: {code} "
              f"(push={push_sent}, email={email_sent})")

        return Response({
            'message': self._SENT_MESSAGE,
            'push_sent': push_sent,
            'email_sent': email_sent,
        }, status=status.HTTP_200_OK)


class ConfirmPasswordResetAPIView(APIView):
    """
    Step 2 of forgot-password: verify the 6-digit code and set the new password.
    The code is single use and dies with the reset.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        email = str(request.data.get('email') or '').strip().lower()
        submitted = str(
            request.data.get('code')
            or request.data.get('otp_code')
            or request.data.get('verification_code')
            or ''
        ).strip()
        new_password = request.data.get('new_password') or ''

        if not email or not submitted or not new_password:
            return Response(
                {'detail': 'Email, code, and new password are required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        pw_problem = password_error(new_password)
        if pw_problem:
            return Response(
                {'detail': pw_problem},
                status=status.HTTP_400_BAD_REQUEST,
            )

        user = User.objects.filter(email__iexact=email).first()
        if user is None:
            return Response(
                {'detail': 'Invalid code. Please request a new one.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        record = PasswordResetCode.objects.filter(user=user).order_by('-created_at').first()
        if record is None:
            return Response(
                {'detail': 'No reset code was requested for this account.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if not record.is_valid():
            record.delete()
            return Response(
                {'detail': 'That code has expired. Please request a new one.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if record.code != submitted:
            return Response(
                {'detail': 'Invalid code. Please check and try again.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        user.set_password(new_password)
        user.save(update_fields=['password'])

        # Burn every code for this user so it cannot be replayed.
        PasswordResetCode.objects.filter(user=user).delete()

        print(f"✅ Password reset completed for {user.username}")

        return Response({
            'message': 'Password reset successful. You can now log in with your new password.',
            'username': user.username,
        }, status=status.HTTP_200_OK)


class RequestChangePasswordCodeAPIView(APIView):
    """
    Step 1 of in-app change password (Profile screen).

    The user is already signed in here, so we demand proof before sending
    anything: the correct CURRENT password and the email already on the
    account. Only then does a confirmation code go out over push + email.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        user_id = request.data.get('user_id')
        current_password = request.data.get('current_password') or ''
        email = str(request.data.get('email') or '').strip().lower()

        if not user_id or not current_password or not email:
            return Response(
                {'detail': 'user_id, current_password, and email are required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            user = User.objects.get(id=user_id)
        except (User.DoesNotExist, ValueError):
            return Response({'detail': 'Account not found.'}, status=status.HTTP_404_NOT_FOUND)

        # Proof #1: they know the current password.
        if not user.check_password(current_password):
            return Response(
                {'detail': 'Your current password is incorrect.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Proof #2: the email typed matches the account. Stops someone on an
        # unlocked phone from redirecting the code to an address they control.
        if (user.email or '').strip().lower() != email:
            return Response(
                {'detail': 'That email does not match the one on your account.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        code = generate_otp()
        PasswordResetCode.objects.filter(user=user).delete()
        PasswordResetCode.objects.create(user=user, code=code)

        # A. Push to the phone - works for every role via User.push_token.
        push_sent = False
        try:
            push_sent = send_change_password_code(user, code)
        except Exception as fcm_err:
            print(f"❌ Change-password push failed: {fcm_err}")

        # B. Email as the fallback channel.
        email_sent = False
        try:
            msg = EmailMultiAlternatives(
                f"{code} is your ISU password change code",
                (
                    f"Hello {user.username},\n\n"
                    f"Your password change confirmation code is: {code}\n\n"
                    f"It expires in 10 minutes. If you did not request this, "
                    f"ignore this email and your password will stay the same."
                ),
                getattr(settings, 'DEFAULT_FROM_EMAIL', 'ISU Support <noreply@isu.edu.ph>'),
                [user.email],
            )
            msg.attach_alternative(f"""
            <div style="font-family: Arial, sans-serif; padding: 20px;">
              <h2>Confirm Your Password Change</h2>
              <p>Hello <strong>{user.username}</strong>,</p>
              <div style="font-size: 30px; font-weight: bold; background-color: #eef2ff;
                          color: #1e40af; padding: 14px 24px; display: inline-block;
                          border-radius: 6px; letter-spacing: 4px;">{code}</div>
              <p>This code expires in 10 minutes.</p>
            </div>
            """, "text/html")
            msg.send()
            email_sent = True
        except Exception as mail_err:
            print(f"❌ Change-password email failed: {mail_err}")

        if not push_sent and not email_sent:
            return Response(
                {'detail': 'Could not deliver your code right now. Please try again later.'},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

        print(f"🔐 Change-password code for {user.username}: {code} "
              f"(push={push_sent}, email={email_sent})")

        return Response({
            'message': 'Confirmation code sent to your phone and email.',
            'push_sent': push_sent,
            'email_sent': email_sent,
        }, status=status.HTTP_200_OK)


class ConfirmChangePasswordAPIView(APIView):
    """
    Step 2 of in-app change password: check the code and apply the new password.

    The current password is re-verified here too - the code alone is not
    enough, in case the phone was left unattended between the two steps.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        user_id = request.data.get('user_id')
        current_password = request.data.get('current_password') or ''
        submitted = str(request.data.get('code') or '').strip()
        new_password = request.data.get('new_password') or ''

        if not user_id or not submitted or not new_password:
            return Response(
                {'detail': 'user_id, code, and new_password are required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        pw_problem = password_error(new_password)
        if pw_problem:
            return Response(
                {'detail': pw_problem},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            user = User.objects.get(id=user_id)
        except (User.DoesNotExist, ValueError):
            return Response({'detail': 'Account not found.'}, status=status.HTTP_404_NOT_FOUND)

        if current_password and not user.check_password(current_password):
            return Response(
                {'detail': 'Your current password is incorrect.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if user.check_password(new_password):
            return Response(
                {'detail': 'Your new password must be different from the current one.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        record = PasswordResetCode.objects.filter(user=user).order_by('-created_at').first()
        if record is None:
            return Response(
                {'detail': 'No confirmation code was requested. Please start again.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if not record.is_valid():
            record.delete()
            return Response(
                {'detail': 'That code has expired. Please request a new one.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if record.code != submitted:
            return Response(
                {'detail': 'Invalid code. Please check and try again.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        user.set_password(new_password)
        user.save(update_fields=['password'])
        PasswordResetCode.objects.filter(user=user).delete()

        # Tell the device the password moved - cheap way to surface a hijack.
        try:
            send_password_changed_alert(user)
        except Exception as alert_err:
            print(f"⚠️ Password-changed alert failed: {alert_err}")

        print(f"✅ Password changed in-app for {user.username}")

        return Response({
            'message': 'Password changed successfully.',
            'username': user.username,
        }, status=status.HTTP_200_OK)


class RegisterDeviceTokenAPIView(APIView):
    """
    Saves the device's FCM token against the User after login.

    Without this, instructors/directors/admins would never receive a push,
    since only the student registration flow ever stored a token.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        user_id = request.data.get('user_id')
        token = str(request.data.get('fcm_token') or '').strip()

        if not user_id or not token:
            return Response(
                {'detail': 'user_id and fcm_token are required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            user = User.objects.get(id=user_id)
        except (User.DoesNotExist, ValueError):
            return Response({'detail': 'Account not found.'}, status=status.HTTP_404_NOT_FOUND)

        user.fcm_token = token
        user.save(update_fields=['fcm_token'])

        # Keep the student copy in step so existing student pushes still land.
        profile = getattr(user, 'student_profile', None)
        if profile is not None and profile.fcm_token != token:
            profile.fcm_token = token
            profile.save(update_fields=['fcm_token'])

        return Response({'message': 'Device registered for notifications.'})


class PasswordResetAPIView(APIView):
    """
    Legacy reset: emails a temporary password. Kept so older builds of the app
    keep working; new clients use request-code/ + confirm/ instead.
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

            # Attendance is scheduled, so nobody may time in early. Without
            # this a student who saw the reminder could check in during the
            # lead time and then leave before the activity actually began.
            now = timezone.now()
            if now < session.date_time:
                starts_in = int((session.date_time - now).total_seconds() // 60)
                local_start = timezone.localtime(session.date_time).strftime('%I:%M %p')
                return Response({
                    "status": "failed",
                    "message": (
                        f"Attendance has not started yet. It opens at {local_start} "
                        f"(in {starts_in} min)."
                    ),
                    "not_started": True,
                    "starts_at": session.date_time.isoformat(),
                }, status=400)

            # The selfie must be submitted inside the session's photo window.
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

                # The app verifies the selfie's face on-device (MediaPipe) and
                # reports the result. A mismatch, missing reference, or no face
                # never blocks time-in: the record is saved but flagged for
                # instructor review (selfie_verified=False).
                face_verified_raw = request.data.get('face_verified')
                if face_verified_raw is not None:
                    # Accept "true"/"True"/1 forms from the app.
                    face_verified = str(face_verified_raw).lower() in ('true', '1', 'yes')
                else:
                    # Older app builds: a selfie being attached counts as its
                    # own (weak) verification, as it always has.
                    face_verified = bool(selfie_file)

                try:
                    face_similarity = float(request.data.get('face_similarity'))
                except (TypeError, ValueError):
                    face_similarity = None

                # Creates the record in your database
                record = AttendanceRecord.objects.create(
                    session=session,
                    student=student_profile,
                    student_latitude=stud_lat,
                    student_longitude=stud_lng,
                    status='Present',
                    mode=mode,
                    student_address=request.data.get('address') or request.data.get('student_address'),
                    selfie_verified=face_verified,
                    selfie_image=selfie_file,
                    face_similarity=face_similarity,
                )

                # Tell the instructor this student just checked in.
                try:
                    send_check_in_notification(record)
                except Exception as push_err:
                    print(f"Check-in push to instructor failed: {push_err}")

                # Queue the random "are you still there?" prompts for this student.
                checks = record.schedule_presence_checks()

                return Response({
                    "status": "success",
                    "message": f"Attendance recorded successfully! You are {distance:.1f}m away.",
                    "record_id": record.id,
                    "face_verified": face_verified,
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
    parser_classes = (MultiPartParser, FormParser)

    def post(self, request):
        check_id = request.data.get('check_id')
        student_id = request.data.get('student_id')

        if not check_id or not student_id:
            return Response({'error': 'check_id and student_id are required'}, status=400)

        # A live front-camera photo is mandatory proof for every presence check.
        photo = request.FILES.get('response_photo')
        if photo is None:
            return Response({
                'error': 'A photo is required to confirm your presence.',
            }, status=400)

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
        check.response_photo = photo
        check.save(update_fields=[
            'status', 'responded_at', 'response_latitude', 'response_longitude',
            'response_photo',
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

        # Attendance is a per-day affair: the roster resets at local midnight
        # and the instructor opens a fresh activity each morning. Without a
        # bound here the newest row wins forever, so a student opening the app
        # the next day would be handed yesterday's finished activity and sent
        # into the check-in flow for it.
        #
        # The exception is an activity that began before midnight and is still
        # inside its window - cutting that one off at 12am would strand the
        # class halfway through, unable to time out.
        now = timezone.now()
        day_start = timezone.make_aware(
            datetime.datetime.combine(timezone.localdate(), datetime.time.min),
            timezone.get_current_timezone(),
        )

        session = None
        for candidate in sessions.filter(
            date_time__gte=day_start - datetime.timedelta(days=1)
        ):
            if candidate.date_time >= day_start or now < candidate.ends_at:
                session = candidate
                break

        if not session:
            return Response(
                {"message": "No attendance session for today yet. "
                            "Ask your instructor to start one."},
                status=404,
            )

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
            session = serializer.save()

            # Fire straight away rather than waiting for the next sweep. A
            # session created to start immediately - or already inside its
            # reminder lead - would otherwise sit silent until some unrelated
            # request happened to arrive, and the class would hear nothing.
            try:
                dispatch_due_session_alerts(force=True)
            except Exception as e:
                # A push failure must never lose the session just saved.
                print(f"Session alert dispatch after create failed: {e}")

            session.refresh_from_db()
            return Response(SessionSerializer(session).data, status=201)
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

        if existing and existing.status != 'removed':
            return Response({'message': 'Already enrolled in this class', 'status': existing.status})

        # A student may only belong to one class at a time. An active or
        # pending enrollment anywhere else blocks joining this one.
        if ClassEnrollment.objects.filter(
            student=student_profile, status__in=['active', 'pending']
        ).exists():
            return Response(
                {'error': 'You can only be enrolled in one class at a time. '
                          'Leave your current class first.'},
                status=403,
            )

        if existing and existing.status == 'removed':
            existing.status = 'pending' if class_group.requires_approval else 'active'
            existing.save()
            return Response({'message': 'Re-enrolled in class', 'status': existing.status})

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

        if existing and existing.status != 'removed':
            return Response({'message': 'Already enrolled in this class', 'status': existing.status})

        # Same one-class-per-student rule as the join-code path: no joining
        # another class while still enrolled somewhere.
        if ClassEnrollment.objects.filter(
            student=student_profile, status__in=['active', 'pending']
        ).exists():
            return Response(
                {'error': 'You can only be enrolled in one class at a time. '
                          'Leave your current class first.'},
                status=403,
            )

        if existing and existing.status == 'removed':
            existing.status = 'pending' if class_group.requires_approval else 'active'
            existing.save()
            return Response({'message': 'Re-enrolled in class', 'status': existing.status})

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


class StudentLeaveClassAPIView(APIView):
    """A student leaves their current class so they can join another one.

    Soft-deletes the enrollment (status 'removed'), which keeps the audit trail
    while freeing the student to join a different class under the one-class
    rule.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        student_id = request.data.get('student_id')  # User ID
        class_id = request.data.get('class_id')

        if not student_id or not class_id:
            return Response({'error': 'student_id and class_id are required'}, status=400)

        try:
            student_user = User.objects.get(id=student_id)
            student_profile = StudentProfile.objects.get(user=student_user)
        except (User.DoesNotExist, StudentProfile.DoesNotExist):
            return Response({'error': 'Student not found'}, status=404)

        enrollment = ClassEnrollment.objects.filter(
            class_group_id=class_id,
            student=student_profile,
            status__in=['active', 'pending'],
        ).first()

        if enrollment is None:
            return Response({'error': 'You are not enrolled in that class.'}, status=404)

        enrollment.status = 'removed'
        enrollment.save(update_fields=['status'])
        return Response({'message': 'You have left the class.', 'status': 'removed'})


# ====================================================================================
# DIRECTOR OVERSIGHT
# ====================================================================================

# Attendance-rate bands used to label a class at a glance.
HEALTH_GOOD_THRESHOLD = 85
HEALTH_FAIR_THRESHOLD = 70


def _health_label(rate, has_data):
    """'good' / 'fair' / 'attention', or 'no_data' before any session runs."""
    if not has_data:
        return 'no_data'
    if rate >= HEALTH_GOOD_THRESHOLD:
        return 'good'
    if rate >= HEALTH_FAIR_THRESHOLD:
        return 'fair'
    return 'attention'


class DirectorOverviewAPIView(APIView):
    """
    Campus-wide picture for the NSTP director: every class, the instructor
    assigned to it, and whether its attendance looks healthy.

    Optional filters: ?component=CWTS, ?instructor_id=<id>.
    """
    permission_classes = [AllowAny]

    def get(self, request):
        component = request.query_params.get('component')
        instructor_id = request.query_params.get('instructor_id')

        classes = ClassGroup.objects.select_related('instructor').order_by('name')
        if component:
            classes = classes.filter(component__iexact=component)
        if instructor_id:
            classes = classes.filter(instructor_id=instructor_id)

        classes = list(classes)
        class_ids = [c.id for c in classes]

        # Roll everything up in three grouped queries instead of per-class hits.
        enrolled = {
            row['class_group_id']: row['n']
            for row in ClassEnrollment.objects
            .filter(class_group_id__in=class_ids, status='active')
            .values('class_group_id').annotate(n=Count('id'))
        }

        sessions = {
            row['class_group_id']: row
            for row in AttendanceSession.objects
            .filter(class_group_id__in=class_ids)
            .values('class_group_id')
            .annotate(
                n=Count('id'),
                last=Max('date_time'),
                open_windows=Count('id', filter=Q(is_check_out_open=True)),
            )
        }

        records = {
            row['session__class_group_id']: row
            for row in AttendanceRecord.objects
            .filter(session__class_group_id__in=class_ids)
            .values('session__class_group_id')
            .annotate(
                total=Count('id'),
                failed=Count('id', filter=Q(presence_status='failed')),
                warned=Count('id', filter=Q(presence_status='warned')),
                checked_out=Count('id', filter=Q(check_out_at__isnull=False)),
            )
        }

        rows = []
        campus_expected = 0
        campus_present = 0
        campus_failed = 0

        for c in classes:
            students = enrolled.get(c.id, 0)
            s = sessions.get(c.id, {})
            r = records.get(c.id, {})

            session_count = s.get('n', 0) or 0
            last_session = s.get('last')
            present = r.get('total', 0) or 0
            failed = r.get('failed', 0) or 0
            warned = r.get('warned', 0) or 0
            checked_out = r.get('checked_out', 0) or 0

            # Approximation: assumes the current roster attended every past
            # session. Students who joined late make this read slightly low.
            expected = session_count * students
            rate = round((present / expected) * 100, 1) if expected else 0.0
            has_data = session_count > 0 and students > 0

            campus_expected += expected
            campus_present += present
            campus_failed += failed

            instructor = c.instructor
            rows.append({
                'class_id': c.id,
                'class_name': c.name,
                'component': c.component or '',
                'section_code': c.section_code or '',
                'instructor_id': instructor.id,
                'instructor_name': instructor.get_full_name() or instructor.username,
                'instructor_email': instructor.email,
                'student_count': students,
                'session_count': session_count,
                'last_session': timezone.localtime(last_session).strftime('%m/%d/%Y %I:%M %p')
                if last_session else None,
                'check_in_count': present,
                'checked_out_count': checked_out,
                'failed_count': failed,
                'warned_count': warned,
                'attendance_rate': rate,
                'health': _health_label(rate, has_data),
                # Flags the director actually acts on.
                'no_sessions_yet': session_count == 0,
                'no_students_yet': students == 0,
            })

        campus_rate = (
            round((campus_present / campus_expected) * 100, 1)
            if campus_expected else 0.0
        )

        # Group the same rows by instructor so the director can see who is
        # assigned to what, and who is falling behind.
        instructors = {}
        for row in rows:
            key = row['instructor_id']
            entry = instructors.setdefault(key, {
                'instructor_id': key,
                'instructor_name': row['instructor_name'],
                'instructor_email': row['instructor_email'],
                'class_count': 0,
                'student_count': 0,
                'session_count': 0,
                'classes_needing_attention': 0,
                'class_names': [],
            })
            entry['class_count'] += 1
            entry['student_count'] += row['student_count']
            entry['session_count'] += row['session_count']
            entry['class_names'].append(row['class_name'])
            if row['health'] == 'attention':
                entry['classes_needing_attention'] += 1

        return Response({
            'summary': {
                'total_classes': len(rows),
                'total_instructors': len(instructors),
                'total_students': sum(r['student_count'] for r in rows),
                'total_sessions': sum(r['session_count'] for r in rows),
                'attendance_rate': campus_rate,
                'failed_verifications': campus_failed,
                'classes_needing_attention': sum(
                    1 for r in rows if r['health'] == 'attention'
                ),
                'classes_without_sessions': sum(1 for r in rows if r['no_sessions_yet']),
                'health': _health_label(campus_rate, campus_expected > 0),
            },
            'instructors': sorted(
                instructors.values(), key=lambda i: i['instructor_name'].lower()
            ),
            'classes': rows,
        })


class DirectorClassSessionsAPIView(APIView):
    """
    Session-by-session breakdown for one class, so the director can see whether
    a particular activity went well rather than only the class average.
    """
    permission_classes = [AllowAny]

    def get(self, request, pk):
        try:
            class_group = ClassGroup.objects.select_related('instructor').get(pk=pk)
        except ClassGroup.DoesNotExist:
            return Response({'error': 'Class not found'}, status=404)

        students = ClassEnrollment.objects.filter(
            class_group=class_group, status='active'
        ).count()

        stats = {
            row['session_id']: row
            for row in AttendanceRecord.objects
            .filter(session__class_group=class_group)
            .values('session_id')
            .annotate(
                total=Count('id'),
                failed=Count('id', filter=Q(presence_status='failed')),
                checked_out=Count('id', filter=Q(check_out_at__isnull=False)),
            )
        }

        sessions = []
        for session in AttendanceSession.objects.filter(
            class_group=class_group
        ).order_by('-date_time'):
            row = stats.get(session.id, {})
            present = row.get('total', 0) or 0
            rate = round((present / students) * 100, 1) if students else 0.0

            sessions.append({
                'session_id': session.id,
                'title': session.title,
                'date_time': timezone.localtime(session.date_time).strftime('%m/%d/%Y %I:%M %p'),
                'expected': students,
                'checked_in': present,
                'checked_out': row.get('checked_out', 0) or 0,
                'failed': row.get('failed', 0) or 0,
                'attendance_rate': rate,
                'health': _health_label(rate, students > 0),
                'is_check_out_open': session.is_check_out_open,
                'target_latitude': str(session.target_latitude),
                'target_longitude': str(session.target_longitude),
            })

        instructor = class_group.instructor
        return Response({
            'class_id': class_group.id,
            'class_name': class_group.name,
            'component': class_group.component or '',
            'section_code': class_group.section_code or '',
            'instructor_name': instructor.get_full_name() or instructor.username,
            'student_count': students,
            'sessions': sessions,
        })


# ====================================================================================
# STUDENT ATTENDANCE HISTORY
# ====================================================================================

class StudentAttendanceHistoryAPIView(APIView):
    """Every session a student was expected at, attended or not.

    Listing only their AttendanceRecords would quietly hide the absences, which
    are the entries that actually matter to a student checking whether they are
    short on hours. So we start from the sessions of the classes they belong to
    and left-join their records, synthesising an 'Absent' row where none exists.

    Sessions that opened before the student enrolled are skipped - they were
    never expected at those, and counting them would invent absences.
    """

    permission_classes = [AllowAny]

    def get(self, request):
        student_id = request.query_params.get('student_id')  # User ID
        if not student_id:
            return Response({'error': 'student_id is required'}, status=400)

        try:
            student_profile = StudentProfile.objects.get(user_id=student_id)
        except StudentProfile.DoesNotExist:
            return Response({'error': 'Student not found'}, status=404)

        # 'pending' students are excluded: their membership is not yet approved,
        # so they are not on the hook for that class's sessions.
        enrollments = ClassEnrollment.objects.filter(
            student=student_profile, status='active'
        ).select_related('class_group')

        # Nothing joined yet - an empty history, not an error.
        if not enrollments:
            return Response({'summary': self._summary([]), 'records': []})

        joined_at_by_class = {e.class_group_id: e.joined_at for e in enrollments}

        sessions = AttendanceSession.objects.filter(
            class_group_id__in=joined_at_by_class.keys()
        ).select_related('class_group').order_by('-date_time')

        records_by_session = {
            record.session_id: record
            for record in AttendanceRecord.objects.filter(
                student=student_profile, session__in=sessions
            )
        }

        rows = []
        for session in sessions:
            # Skip anything that ran before they joined the class.
            joined_at = joined_at_by_class.get(session.class_group_id)
            if joined_at and session.date_time < joined_at:
                continue

            record = records_by_session.get(session.id)
            rows.append(self._row(session, record))

        return Response({'summary': self._summary(rows), 'records': rows})

    def _row(self, session, record):
        """Flatten one session + optional record into a display row."""
        class_group = session.class_group
        base = {
            'session_id': session.id,
            'title': session.title,
            'class_name': class_group.name if class_group else 'Unassigned',
            'component': (class_group.component or '') if class_group else '',
            'date_time': timezone.localtime(session.date_time).strftime('%m/%d/%Y %I:%M %p'),
            'date_sort': session.date_time.isoformat(),
        }

        if record is None:
            # No record at all: they never timed in.
            base.update({
                'status': 'Absent',
                'attended': False,
                'time_in': None,
                'time_out': None,
                'presence_status': None,
                'missed_checks': 0,
                'responded_checks': 0,
                'total_checks': 0,
                'selfie_verified': False,
                'face_similarity': None,
                'note': 'No time-in recorded for this activity.',
            })
            return base

        checks = record.presence_checks.all()
        responded = sum(1 for c in checks if c.status == 'responded')

        # A failed presence check means they timed in but could not prove they
        # stayed, so surface that rather than a bare 'Present'.
        if record.presence_status == 'failed':
            note = (
                f'Timed in, but missed {record.missed_checks} presence check(s), '
                'so attendance could not be verified.'
            )
        elif record.check_out_at is None:
            note = 'Timed in but never timed out.'
        else:
            note = None

        base.update({
            'status': record.status,
            'attended': True,
            'time_in': timezone.localtime(record.timestamp).strftime('%I:%M %p'),
            'time_out': (
                timezone.localtime(record.check_out_at).strftime('%I:%M %p')
                if record.check_out_at else None
            ),
            'presence_status': record.presence_status,
            'missed_checks': record.missed_checks,
            'responded_checks': responded,
            'total_checks': len(checks),
            'selfie_verified': record.selfie_verified,
            'face_similarity': record.face_similarity,
            'note': note,
        })
        return base

    def _summary(self, rows):
        """Headline counts for the top of the history screen."""
        total = len(rows)
        # 'Verified' is the honest measure: timed in AND presence confirmed.
        verified = sum(
            1 for r in rows
            if r['attended'] and r.get('presence_status') != 'failed'
        )
        absent = sum(1 for r in rows if not r['attended'])
        unverified = total - verified - absent

        return {
            'total_sessions': total,
            'verified': verified,
            'unverified': unverified,
            'absent': absent,
            'attendance_rate': round((verified / total) * 100, 1) if total else 0.0,
        }


# ====================================================================================
# CLASS ATTENDANCE RECORD (per class, per calendar date) + CSV EXPORT
# ====================================================================================

# Column order for the exported CSV. Kept in one place so the header row and
# the data rows can never drift apart.
CSV_COLUMNS = [
    ('student_id', 'Student ID'),
    ('student_name', 'Student Name'),
    ('course_and_section', 'Course & Section'),
    ('activity', 'Activity'),
    ('activity_time', 'Activity Time'),
    ('status', 'Status'),
    ('excused', 'Excused'),
    ('time_in', 'Time In'),
    ('time_out', 'Time Out'),
    ('presence_status', 'Presence Verification'),
    ('responded_checks', 'Checks Answered'),
    ('missed_checks', 'Checks Missed'),
    ('selfie_verified', 'Selfie Verified'),
    ('remarks', 'Remarks'),
]

PRESENCE_LABELS = {
    'ok': 'Verified',
    'warned': 'Warned',
    'failed': 'Failed',
}


class ClassAttendanceDatesAPIView(APIView):
    """
    Which calendar dates this class actually held activities on.

    The app's calendar marks these dates so the instructor taps a day that has
    data instead of hunting through empty ones.
    """

    permission_classes = [AllowAny]

    def get(self, request, pk):
        try:
            class_group = ClassGroup.objects.get(pk=pk)
        except ClassGroup.DoesNotExist:
            return Response({'error': 'Class not found'}, status=404)

        sessions = AttendanceSession.objects.filter(
            class_group=class_group
        ).order_by('-date_time')

        # Group by local calendar date - a 10pm UTC session belongs to the day
        # the instructor actually ran it, not the UTC day.
        dates = {}
        for session in sessions:
            local_dt = timezone.localtime(session.date_time)
            key = local_dt.strftime('%Y-%m-%d')
            entry = dates.setdefault(key, {'date': key, 'sessions': 0, 'titles': []})
            entry['sessions'] += 1
            entry['titles'].append(session.title)

        return Response({
            'class_id': class_group.id,
            'class_name': class_group.name,
            'dates': list(dates.values()),
        })


class ClassAttendanceRecordsAPIView(APIView):
    """
    Full attendance record for one class, optionally narrowed to one date.

    Add `?export=csv` to get the same rows as a downloadable file. The CSV is
    built from the identical row list the JSON response uses, so what the
    instructor sees on screen is exactly what they export.

    The parameter is `export` rather than the more obvious `format` because DRF
    reserves `format` for content negotiation and answers 404 for a suffix it
    has no renderer for.
    """

    permission_classes = [AllowAny]

    def get(self, request, pk):
        try:
            class_group = ClassGroup.objects.select_related('instructor').get(pk=pk)
        except ClassGroup.DoesNotExist:
            return Response({'error': 'Class not found'}, status=404)

        sessions = AttendanceSession.objects.filter(class_group=class_group)

        date_param = request.query_params.get('date')
        if date_param:
            try:
                target = datetime.datetime.strptime(date_param, '%Y-%m-%d').date()
            except ValueError:
                return Response(
                    {'error': 'date must look like YYYY-MM-DD'}, status=400
                )
            # Filter on an explicit local-midnight-to-midnight range instead of
            # __date. A __date lookup makes MySQL call CONVERT_TZ(), which
            # returns NULL - and therefore matches nothing at all - unless the
            # server's timezone tables have been loaded.
            start, end = self._local_day_bounds(target)
            sessions = sessions.filter(date_time__gte=start, date_time__lt=end)

        session_param = request.query_params.get('session_id')
        if session_param:
            sessions = sessions.filter(id=session_param)

        sessions = sessions.order_by('date_time')

        # Everyone currently on the roster; absences only make sense against it.
        enrollments = ClassEnrollment.objects.filter(
            class_group=class_group, status='active'
        ).select_related('student__user')

        records = AttendanceRecord.objects.filter(
            session__in=sessions
        ).select_related('student__user').prefetch_related('presence_checks')

        by_session_student = {
            (record.session_id, record.student_id): record for record in records
        }

        # Approved excuses turn what would read as an absence into 'Excused'.
        # A letter still awaiting review changes nothing about the record.
        excused = set(
            AttendanceExcuse.objects.filter(
                session__in=sessions, status='approved'
            ).values_list('session_id', 'student_id')
        )

        rows = []
        for session in sessions:
            for enrollment in enrollments:
                # Students who joined after the activity ran were never
                # expected there, so they must not show up as absent.
                if enrollment.joined_at and session.date_time < enrollment.joined_at:
                    continue

                record = by_session_student.get((session.id, enrollment.student_id))
                is_excused = (session.id, enrollment.student_id) in excused
                rows.append(
                    self._row(session, enrollment.student, record, is_excused)
                )

        payload = {
            'class_id': class_group.id,
            'class_name': class_group.name,
            'component': class_group.component or '',
            'section_code': class_group.section_code or '',
            'instructor_name': (
                class_group.instructor.get_full_name()
                or class_group.instructor.username
            ),
            'date': date_param or '',
            'summary': self._summary(rows),
            'records': rows,
        }

        if request.query_params.get('export') == 'csv':
            return self._csv_response(class_group, date_param, rows)

        return Response(payload)

    @staticmethod
    def _local_day_bounds(target_date):
        """The UTC instants that bracket [target_date] in the local timezone."""
        tz = timezone.get_current_timezone()
        start = timezone.make_aware(
            datetime.datetime.combine(target_date, datetime.time.min), tz
        )
        return start, start + datetime.timedelta(days=1)

    def _row(self, session, student, record, is_excused=False):
        user = student.user
        local_session = timezone.localtime(session.date_time)

        row = {
            'session_id': session.id,
            'student_id': student.student_id or user.username,
            'student_name': user.get_full_name() or user.username,
            'course_and_section': student.course_and_section or '',
            'activity': session.title,
            'activity_date': local_session.strftime('%Y-%m-%d'),
            'activity_time': local_session.strftime('%I:%M %p'),
            'excused': is_excused,
            'session_latitude': str(session.target_latitude),
            'session_longitude': str(session.target_longitude),
        }

        if record is None:
            row.update({
                # An approved excuse is the difference between a no-show and a
                # sanctioned absence, so the two must not read the same.
                'status': 'Excused' if is_excused else 'Absent',
                'attended': False,
                'time_in': '',
                'time_out': '',
                'presence_status': '',
                'responded_checks': 0,
                'missed_checks': 0,
                'total_checks': 0,
                'selfie_verified': False,
                'face_similarity': None,
                'remarks': (
                    'Absence excused by instructor.' if is_excused
                    else 'No time-in recorded.'
                ),
            })
            return row

        checks = list(record.presence_checks.all())
        responded = sum(1 for c in checks if c.status == 'responded')

        if record.presence_status == 'failed':
            remarks = (
                f'Timed in but missed {record.missed_checks} presence check(s); '
                'attendance not verified.'
            )
        elif record.presence_status == 'warned':
            remarks = 'Missed one presence check.'
        elif record.check_out_at is None:
            remarks = 'Timed in but never timed out.'
        else:
            remarks = ''

        # They turned up but missed a ping, and the instructor accepted the
        # explanation. Note it beside the failure rather than erasing it.
        if is_excused and record.presence_status in ('warned', 'failed'):
            remarks = f'{remarks} Missed check(s) excused by instructor.'.strip()

        row.update({
            'status': record.status,
            'attended': True,
            'time_in': timezone.localtime(record.timestamp).strftime('%I:%M %p'),
            'time_out': (
                timezone.localtime(record.check_out_at).strftime('%I:%M %p')
                if record.check_out_at else ''
            ),
            'presence_status': PRESENCE_LABELS.get(
                record.presence_status, record.presence_status or ''
            ),
            'responded_checks': responded,
            'missed_checks': record.missed_checks,
            'total_checks': len(checks),
            'selfie_verified': record.selfie_verified,
            'face_similarity': record.face_similarity,
            'remarks': remarks,
        })
        return row

    def _summary(self, rows):
        total = len(rows)
        present = sum(1 for r in rows if r['attended'])
        verified = sum(
            1 for r in rows if r['attended'] and r['presence_status'] != 'Failed'
        )
        # An excused absence is not an attendance, but it is not held against
        # the student either - so it leaves the absent tally and the
        # denominator behind the rate.
        excused = sum(1 for r in rows if not r['attended'] and r.get('excused'))
        counted = total - excused
        return {
            'expected': total,
            'present': present,
            'absent': total - present - excused,
            'excused': excused,
            'verified': verified,
            'failed': sum(1 for r in rows if r['presence_status'] == 'Failed'),
            'attendance_rate': round((present / counted) * 100, 1) if counted else 0.0,
        }

    def _csv_response(self, class_group, date_param, rows):
        """Streams the rows as a CSV attachment."""
        response = HttpResponse(content_type='text/csv')

        # Spaces and slashes in a class name would make an awkward filename.
        safe_name = re.sub(r'[^A-Za-z0-9]+', '_', class_group.name).strip('_')
        suffix = date_param or 'all-dates'
        filename = f'attendance_{safe_name}_{suffix}.csv'
        response['Content-Disposition'] = f'attachment; filename="{filename}"'

        writer = csv.writer(response)
        writer.writerow([label for _, label in CSV_COLUMNS])

        for row in rows:
            writer.writerow([self._cell(row, key) for key, _ in CSV_COLUMNS])

        return response

    @staticmethod
    def _cell(row, key):
        """One CSV cell. Booleans read better as Yes/No than True/False."""
        value = row.get(key, '')
        if isinstance(value, bool):
            return 'Yes' if value else 'No'
        return '' if value is None else value


# ====================================================================================
# EXCUSE LETTERS (student explains a missed ping or a no-show)
# ====================================================================================

class StudentExcuseAPIView(APIView):
    """
    GET  - the excuses this student has filed, newest first.
    POST - file (or revise) an excuse for one activity.

    The `kind` is decided here from the attendance data, never from the
    request body: if a record exists the student timed in and is excusing a
    missed presence check, otherwise they are excusing a no-show. Trusting the
    client with that would let anyone relabel their own absence.
    """

    permission_classes = [AllowAny]
    # JSON as well as multipart: the attachment is optional, and most letters
    # are filed as plain text. Accepting only multipart would reject those
    # with a 415 the student could do nothing about.
    parser_classes = (MultiPartParser, FormParser, JSONParser)

    def get(self, request):
        student_id = request.query_params.get('student_id')
        if not student_id:
            return Response({'error': 'student_id is required'}, status=400)

        try:
            profile = StudentProfile.objects.get(user_id=student_id)
        except StudentProfile.DoesNotExist:
            return Response({'error': 'Student not found'}, status=404)

        excuses = AttendanceExcuse.objects.filter(
            student=profile
        ).select_related('session__class_group', 'student__user', 'reviewed_by')

        session_id = request.query_params.get('session_id')
        if session_id:
            excuses = excuses.filter(session_id=session_id)

        serializer = AttendanceExcuseSerializer(
            excuses, many=True, context={'request': request}
        )
        return Response(serializer.data)

    def post(self, request):
        student_id = request.data.get('student_id')
        session_id = request.data.get('session_id')
        reason = str(request.data.get('reason') or '').strip()

        if not student_id or not session_id or not reason:
            return Response(
                {'error': 'student_id, session_id, and reason are required.'},
                status=400,
            )

        try:
            profile = StudentProfile.objects.select_related('user').get(user_id=student_id)
        except StudentProfile.DoesNotExist:
            return Response({'error': 'Student not found'}, status=404)

        try:
            session = AttendanceSession.objects.select_related(
                'class_group', 'instructor'
            ).get(id=session_id)
        except AttendanceSession.DoesNotExist:
            return Response({'error': 'Activity not found'}, status=404)

        # Only an approved member of the class may file against its activities.
        if session.class_group_id:
            is_member = ClassEnrollment.objects.filter(
                class_group_id=session.class_group_id,
                student=profile,
                status='active',
            ).exists()
            if not is_member:
                return Response(
                    {'error': 'You are not an approved member of this class.'},
                    status=403,
                )

        now = timezone.now()
        is_future = now < session.date_time

        # --- Future absence: student knows they cannot attend ---
        if is_future:
            kind = 'future_absence'
            record = None

            # A clean attendance needs no excuse.
            existing = AttendanceExcuse.objects.filter(
                session=session, student=profile
            ).first()

            if existing and existing.status != 'pending':
                return Response(
                    {
                        'error': (
                            f'Your excuse for this activity was already '
                            f'{existing.status}. Please talk to your instructor.'
                        ),
                        'status': existing.status,
                    },
                    status=409,
                )

            attachment = request.FILES.get('attachment')

            if existing:
                existing.reason = reason
                existing.kind = kind
                existing.record = None
                if attachment:
                    existing.attachment = attachment
                existing.save()
                excuse = existing
                created = False
            else:
                excuse = AttendanceExcuse.objects.create(
                    session=session,
                    student=profile,
                    record=None,
                    kind=kind,
                    reason=reason,
                    attachment=attachment,
                )
                created = True

            try:
                send_excuse_submitted(excuse)
            except Exception as push_err:
                print(f"Excuse push to instructor failed: {push_err}")

            serializer = AttendanceExcuseSerializer(
                excuse, context={'request': request}
            )
            return Response(
                {
                    'message': (
                        'Excuse submitted. Your instructor has been notified.'
                        if created else
                        'Excuse updated. Your instructor has been notified.'
                    ),
                    'excuse': serializer.data,
                },
                status=201 if created else 200,
            )

        # --- Retroactive excuse: session already started or finished ---
        record = AttendanceRecord.objects.filter(
            session=session, student=profile
        ).first()

        # Derive the kind from the data rather than trusting the client.
        kind = 'missed_check' if record else 'absent'

        # A clean attendance needs no excuse - reject rather than clutter the
        # instructor's queue with letters that explain nothing.
        if record and record.presence_status == 'ok' and record.check_out_at:
            return Response(
                {'error': 'Your attendance for this activity is already complete.'},
                status=400,
            )

        existing = AttendanceExcuse.objects.filter(
            session=session, student=profile
        ).first()

        # Once the instructor has ruled, the student cannot quietly re-file.
        if existing and existing.status != 'pending':
            return Response(
                {
                    'error': (
                        f'Your excuse for this activity was already '
                        f'{existing.status}. Please talk to your instructor.'
                    ),
                    'status': existing.status,
                },
                status=409,
            )

        attachment = request.FILES.get('attachment')

        if existing:
            # Still pending: treat a re-submission as an edit.
            existing.reason = reason
            existing.kind = kind
            existing.record = record
            if attachment:
                existing.attachment = attachment
            existing.save()
            excuse = existing
            created = False
        else:
            excuse = AttendanceExcuse.objects.create(
                session=session,
                student=profile,
                record=record,
                kind=kind,
                reason=reason,
                attachment=attachment,
            )
            created = True

        try:
            send_excuse_submitted(excuse)
        except Exception as push_err:
            # A dead token must not lose the student's letter.
            print(f"⚠️ Excuse push to instructor failed: {push_err}")

        serializer = AttendanceExcuseSerializer(excuse, context={'request': request})
        return Response(
            {
                'message': (
                    'Excuse submitted. Your instructor has been notified.'
                    if created else 'Excuse updated. Your instructor has been notified.'
                ),
                'excuse': serializer.data,
            },
            status=201 if created else 200,
        )


class InstructorExcuseListAPIView(APIView):
    """
    The instructor's review queue: every excuse filed against their sessions.

    Defaults to pending only, since that is the actionable list. Pass
    `?status=all` (or approved/rejected) to see what has already been decided.
    """

    permission_classes = [AllowAny]

    def get(self, request):
        instructor_id = request.query_params.get('instructor_id')
        if not instructor_id:
            return Response({'error': 'instructor_id is required'}, status=400)

        excuses = AttendanceExcuse.objects.filter(
            session__instructor_id=instructor_id
        ).select_related('session__class_group', 'student__user', 'reviewed_by')

        status_filter = (request.query_params.get('status') or 'pending').lower()
        if status_filter != 'all':
            excuses = excuses.filter(status=status_filter)

        class_id = request.query_params.get('class_id')
        if class_id:
            excuses = excuses.filter(session__class_group_id=class_id)

        serializer = AttendanceExcuseSerializer(
            excuses, many=True, context={'request': request}
        )
        return Response({
            'pending_count': AttendanceExcuse.objects.filter(
                session__instructor_id=instructor_id, status='pending'
            ).count(),
            'excuses': serializer.data,
        })


class ReviewExcuseAPIView(APIView):
    """
    Instructor approves or rejects one excuse.

    Approving an `absent` excuse is what turns that student's row from Absent
    into Excused in the class record and CSV export. Approving a
    `missed_check` excuse is recorded and shown, but deliberately does NOT
    hand back the time-out window - presence verification stands on its own.
    """

    permission_classes = [AllowAny]

    def patch(self, request, pk):
        instructor_id = request.data.get('instructor_id')
        decision = str(request.data.get('decision') or '').strip().lower()
        note = str(request.data.get('response_note') or '').strip()

        if not instructor_id:
            return Response({'error': 'instructor_id is required'}, status=400)

        if decision not in ('approve', 'reject'):
            return Response(
                {'error': "decision must be either 'approve' or 'reject'."},
                status=400,
            )

        try:
            excuse = AttendanceExcuse.objects.select_related(
                'session__class_group', 'student__user', 'record', 'reviewed_by'
            ).get(pk=pk)
        except AttendanceExcuse.DoesNotExist:
            return Response({'error': 'Excuse not found'}, status=404)

        # Only the instructor who owns the activity may rule on it.
        if str(excuse.session.instructor_id) != str(instructor_id):
            return Response(
                {'error': 'Only the instructor who owns this activity can review it.'},
                status=403,
            )

        if excuse.status != 'pending':
            return Response(
                {
                    'error': f'This excuse was already {excuse.status}.',
                    'status': excuse.status,
                },
                status=409,
            )

        try:
            reviewer = User.objects.get(id=instructor_id)
        except (User.DoesNotExist, ValueError):
            return Response({'error': 'Instructor account not found.'}, status=404)

        excuse.status = 'approved' if decision == 'approve' else 'rejected'
        excuse.response_note = note or None
        excuse.reviewed_by = reviewer
        excuse.reviewed_at = timezone.now()
        excuse.save(update_fields=[
            'status', 'response_note', 'reviewed_by', 'reviewed_at'
        ])

        # An approved no-show stops counting as an absence. Where a record
        # somehow exists we mark it Excused; where it does not (the usual case)
        # the class-record view reads the approved excuse and labels the row,
        # rather than inventing an attendance row with fake coordinates.
        if (
            excuse.status == 'approved'
            and excuse.kind == 'absent'
            and excuse.record is not None
            and excuse.record.status == 'Absent'
        ):
            excuse.record.status = 'Excused'
            excuse.record.save(update_fields=['status'])

        try:
            send_excuse_reviewed(excuse)
        except Exception as push_err:
            print(f"⚠️ Excuse decision push failed: {push_err}")

        serializer = AttendanceExcuseSerializer(excuse, context={'request': request})
        return Response({
            'message': f'Excuse {excuse.status}. The student has been notified.',
            'excuse': serializer.data,
        })


# ------------------------------------------------------------------
# Geofence leave requests
# ------------------------------------------------------------------

class RequestLeaveAPIView(APIView):
    """
    Student requests to temporarily leave the activity geofence.

    POST { student_id, session_id, reason }

    Creates a GeofenceLeaveRequest with a 15-minute deadline and notifies
    the instructor via FCM.
    """

    permission_classes = [AllowAny]

    def post(self, request):
        student_id = request.data.get('student_id')
        session_id = request.data.get('session_id')
        reason = str(request.data.get('reason') or '').strip()

        if not student_id or not session_id or not reason:
            return Response(
                {'error': 'student_id, session_id, and reason are required.'},
                status=400,
            )

        try:
            profile = StudentProfile.objects.select_related('user').get(
                user_id=student_id
            )
        except StudentProfile.DoesNotExist:
            return Response({'error': 'Student not found'}, status=404)

        try:
            session = AttendanceSession.objects.get(id=session_id)
        except AttendanceSession.DoesNotExist:
            return Response({'error': 'Activity not found'}, status=404)

        # Must have an active attendance record for this session.
        record = AttendanceRecord.objects.filter(
            session=session, student=profile
        ).first()
        if not record:
            return Response(
                {'error': 'You must check in before requesting to leave.'},
                status=400,
            )

        # Cannot request leave if already checked out.
        if record.check_out_at is not None:
            return Response(
                {'error': 'You have already checked out from this activity.'},
                status=400,
            )

        # Check for an existing active or pending leave request.
        existing_active = GeofenceLeaveRequest.objects.filter(
            record=record,
            status__in=('pending', 'approved'),
            returned_at__isnull=True,
        ).first()
        if existing_active:
            return Response(
                {'error': 'You already have an active leave request for this activity.'},
                status=400,
            )

        now = timezone.now()
        deadline = now + datetime.timedelta(
            minutes=GeofenceLeaveRequest.LEAVE_DURATION_MINUTES
        )

        leave = GeofenceLeaveRequest.objects.create(
            record=record,
            session=session,
            student=profile,
            reason=reason,
            deadline=deadline,
            status='approved',  # Auto-approve: student can leave immediately
        )

        try:
            send_leave_request_notification(leave)
        except Exception as push_err:
            print(f"Leave push to instructor failed: {push_err}")

        serializer = GeofenceLeaveRequestSerializer(
            leave, context={'request': request}
        )
        return Response(
            {
                'message': (
                    'Leave request approved. You have '
                    f'{GeofenceLeaveRequest.LEAVE_DURATION_MINUTES} minutes to return.'
                ),
                'leave': serializer.data,
            },
            status=201,
        )


class LeaveLocationUpdateAPIView(APIView):
    """
    Student's app sends GPS while they are outside the geofence.

    POST { student_id, leave_id, latitude, longitude }

    Updates the leave request's current location so the instructor can
    track the student.
    """

    permission_classes = [AllowAny]

    def post(self, request):
        student_id = request.data.get('student_id')
        leave_id = request.data.get('leave_id')
        latitude = request.data.get('latitude')
        longitude = request.data.get('longitude')

        if not student_id or not leave_id:
            return Response(
                {'error': 'student_id and leave_id are required.'},
                status=400,
            )

        try:
            leave = GeofenceLeaveRequest.objects.select_related(
                'student__user'
            ).get(id=leave_id, student__user_id=student_id)
        except GeofenceLeaveRequest.DoesNotExist:
            return Response({'error': 'Leave request not found'}, status=404)

        if leave.status != 'approved' or leave.returned_at is not None:
            return Response(
                {'error': 'This leave request is no longer active.'},
                status=400,
            )

        if latitude is not None and longitude is not None:
            leave.return_latitude = latitude
            leave.return_longitude = longitude
            # We reuse return_latitude/longitude as "current" location
            # while the student is outside.  They get overwritten with
            # the actual return location when the student comes back.
            leave.save(update_fields=['return_latitude', 'return_longitude'])

        return Response({'status': 'ok'})


class ReturnToGeofenceAPIView(APIView):
    """
    Student confirms they are back within the activity geofence.

    POST { student_id, leave_id, latitude, longitude }

    Validates the student is actually within the session radius, then
    marks the leave as returned.
    """

    permission_classes = [AllowAny]

    def post(self, request):
        student_id = request.data.get('student_id')
        leave_id = request.data.get('leave_id')
        latitude = request.data.get('latitude')
        longitude = request.data.get('longitude')

        if not student_id or not leave_id:
            return Response(
                {'error': 'student_id and leave_id are required.'},
                status=400,
            )

        try:
            leave = GeofenceLeaveRequest.objects.select_related(
                'session', 'student__user'
            ).get(id=leave_id, student__user_id=student_id)
        except GeofenceLeaveRequest.DoesNotExist:
            return Response({'error': 'Leave request not found'}, status=404)

        if leave.status != 'approved' or leave.returned_at is not None:
            return Response(
                {'error': 'This leave request is no longer active.'},
                status=400,
            )

        if latitude is None or longitude is None:
            return Response(
                {'error': 'latitude and longitude are required.'},
                status=400,
            )

        # Validate the student is actually within the geofence.
        distance = geodesic(
            (float(latitude), float(longitude)),
            (
                float(leave.session.target_latitude),
                float(leave.session.target_longitude),
            ),
        ).meters

        if distance > leave.session.radius_meters:
            return Response(
                {
                    'error': (
                        f'You are still {distance:.0f}m from the activity site. '
                        'Please return to the area first.'
                    ),
                    'distance': round(distance, 1),
                },
                status=400,
            )

        now = timezone.now()
        leave.returned_at = now
        leave.return_latitude = latitude
        leave.return_longitude = longitude

        # If before the deadline, mark as returned; otherwise the expiry
        # dispatcher may have already marked it deserted.
        if leave.status == 'approved':
            leave.status = 'returned'

        leave.save(update_fields=[
            'returned_at', 'return_latitude', 'return_longitude', 'status',
        ])

        serializer = GeofenceLeaveRequestSerializer(
            leave, context={'request': request}
        )
        return Response(
            {
                'message': 'Welcome back! Your return has been recorded.',
                'leave': serializer.data,
            },
        )


class LeaveStatusAPIView(APIView):
    """
    Student polls the current leave status and timer.

    GET ?student_id=<id>&session_id=<id>

    Returns the most recent leave request for this student + session so the
    app can show the countdown and status.
    """

    permission_classes = [AllowAny]

    def get(self, request):
        student_id = request.query_params.get('student_id')
        session_id = request.query_params.get('session_id')

        if not student_id or not session_id:
            return Response(
                {'error': 'student_id and session_id are required.'},
                status=400,
            )

        try:
            profile = StudentProfile.objects.get(user_id=student_id)
        except StudentProfile.DoesNotExist:
            return Response({'error': 'Student not found'}, status=404)

        leave = (
            GeofenceLeaveRequest.objects
            .filter(student=profile, session_id=session_id)
            .select_related('session__instructor', 'student__user')
            .order_by('-requested_at')
            .first()
        )

        if not leave:
            return Response({'leave': None})

        serializer = GeofenceLeaveRequestSerializer(
            leave, context={'request': request}
        )
        return Response({'leave': serializer.data})


class PendingLeavesAPIView(APIView):
    """
    Instructor sees pending leave requests for their sessions today.

    GET ?instructor_id=<id>
    """

    permission_classes = [AllowAny]

    def get(self, request):
        instructor_id = request.query_params.get('instructor_id')
        if not instructor_id:
            return Response(
                {'error': 'instructor_id is required'}, status=400
            )

        today = timezone.now().date()
        leaves = (
            GeofenceLeaveRequest.objects
            .filter(
                session__instructor_id=instructor_id,
                session__date_time__date=today,
            )
            .select_related('session__instructor', 'student__user')
            .order_by('-requested_at')
        )

        status_filter = (request.query_params.get('status') or 'all').lower()
        if status_filter != 'all':
            leaves = leaves.filter(status=status_filter)

        serializer = GeofenceLeaveRequestSerializer(
            leaves, many=True, context={'request': request}
        )
        return Response({
            'pending_count': GeofenceLeaveRequest.objects.filter(
                session__instructor_id=instructor_id,
                session__date_time__date=today,
                status='pending',
            ).count(),
            'leaves': serializer.data,
        })


class ReviewLeaveAPIView(APIView):
    """
    Instructor approves or rejects one leave request.

    PATCH { instructor_id, decision: 'approve'|'reject', response_note? }
    """

    permission_classes = [AllowAny]

    def patch(self, request, pk):
        instructor_id = request.data.get('instructor_id')
        decision = str(request.data.get('decision') or '').strip().lower()
        note = str(request.data.get('response_note') or '').strip()

        if not instructor_id:
            return Response(
                {'error': 'instructor_id is required'}, status=400
            )

        if decision not in ('approve', 'reject'):
            return Response(
                {'error': "decision must be either 'approve' or 'reject'."},
                status=400,
            )

        try:
            leave = GeofenceLeaveRequest.objects.select_related(
                'session__instructor', 'student__user'
            ).get(pk=pk)
        except GeofenceLeaveRequest.DoesNotExist:
            return Response({'error': 'Leave request not found'}, status=404)

        if str(leave.session.instructor_id) != str(instructor_id):
            return Response(
                {'error': 'Only the instructor who owns this activity can review it.'},
                status=403,
            )

        if leave.status != 'pending':
            return Response(
                {
                    'error': f'This leave request was already {leave.status}.',
                    'status': leave.status,
                },
                status=409,
            )

        try:
            reviewer = User.objects.get(id=instructor_id)
        except (User.DoesNotExist, ValueError):
            return Response(
                {'error': 'Instructor account not found.'}, status=404
            )

        if decision == 'approve':
            leave.status = 'approved'
            leave.deadline = timezone.now() + datetime.timedelta(
                minutes=GeofenceLeaveRequest.LEAVE_DURATION_MINUTES
            )
        else:
            leave.status = 'rejected'

        leave.response_note = note or None
        leave.reviewed_by = reviewer
        leave.reviewed_at = timezone.now()
        leave.save(update_fields=[
            'status', 'deadline', 'response_note', 'reviewed_by', 'reviewed_at',
        ])

        try:
            send_leave_reviewed(leave)
        except Exception as push_err:
            print(f"Leave review push failed: {push_err}")

        serializer = GeofenceLeaveRequestSerializer(
            leave, context={'request': request}
        )
        return Response({
            'message': f'Leave request {leave.status}. The student has been notified.',
            'leave': serializer.data,
        })


class UpcomingSessionsForStudentAPIView(APIView):
    """
    Sessions from the student's enrolled classes that have not started yet.

    Excludes sessions the student has already filed an excuse for, so the
    "File an Excuse" screen only offers sessions that still need a letter.

    GET ?student_id=<id>
    """

    permission_classes = [AllowAny]

    def get(self, request):
        student_id = request.query_params.get('student_id')
        if not student_id:
            return Response({'error': 'student_id is required'}, status=400)

        try:
            profile = StudentProfile.objects.get(user_id=student_id)
        except StudentProfile.DoesNotExist:
            return Response({'error': 'Student not found'}, status=404)

        enrollments = ClassEnrollment.objects.filter(
            student=profile, status='active'
        ).select_related('class_group')

        if not enrollments:
            return Response({'sessions': []})

        class_ids = list(enrollments.values_list('class_group_id', flat=True))

        now = timezone.now()

        sessions = (
            AttendanceSession.objects
            .filter(class_group_id__in=class_ids, date_time__gt=now)
            .select_related('class_group')
            .order_by('date_time')
        )

        # Exclude sessions that already have an excuse filed (pending or decided).
        excused_session_ids = set(
            AttendanceExcuse.objects
            .filter(student=profile, session__in=sessions)
            .values_list('session_id', flat=True)
        )

        rows = []
        for session in sessions:
            if session.id in excused_session_ids:
                continue
            rows.append({
                'session_id': session.id,
                'title': session.title,
                'class_name': session.class_group.name if session.class_group else 'Unassigned',
                'date_time': timezone.localtime(session.date_time).strftime('%m/%d/%Y'),
                'start_time': timezone.localtime(session.date_time).strftime('%I:%M %p'),
            })

        return Response({'sessions': rows})

class RequestAccountDeletionAPIView(APIView):
    """
    In-app account deletion request (Profile screen).

    Matches the app's existing proof pattern (user_id + password + email, no
    bearer tokens) so every role can submit. Creates a pending
    AccountDeletionRequest that an NSTP admin processes in /admin/, preserving
    institutional attendance records until a human confirms the deletion.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        user_id = request.data.get('user_id')
        password = request.data.get('password') or ''
        email = str(request.data.get('email') or '').strip().lower()
        reason = request.data.get('reason', '').strip()

        if not user_id or not password or not email:
            return Response(
                {'detail': 'user_id, password, and email are required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            user = User.objects.get(id=user_id)
        except (User.DoesNotExist, ValueError):
            return Response({'detail': 'Account not found.'}, status=status.HTTP_404_NOT_FOUND)

        # Same proof the change-password flow requires.
        if not user.check_password(password):
            return Response(
                {'detail': 'Incorrect password. Your request was not submitted.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if (user.email or '').strip().lower() != email:
            return Response(
                {'detail': 'That email does not match the one on your account.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # One live request per user - a new one retires the old.
        AccountDeletionRequest.objects.filter(
            user=user, status='pending'
        ).delete()

        AccountDeletionRequest.objects.create(
            user=user,
            email=user.email,
            reason=reason,
        )

        # Notify the user their request was received.
        try:
            msg = EmailMultiAlternatives(
                'Account deletion request received - ISU NSTP Attendance',
                (
                    f"Hello {user.get_full_name() or user.username},\n\n"
                    f"We received your request to delete your ISU NSTP Attendance "
                    f"account and the data associated with it.\n\n"
                    f"Your request is now pending review by an NSTP administrator. "
                    f"You will receive another email once it has been processed.\n\n"
                    f"If you did not submit this request, please contact the NSTP "
                    f"office immediately.\n\n"
                    f"- ISU NSTP Support"
                ),
                getattr(settings, 'DEFAULT_FROM_EMAIL'),
                [user.email],
            )
            msg.send()
        except Exception as email_err:
            print(f"❌ Failed to send deletion ack email to {user.email}: {email_err}")

        return Response(
            {
                'message': (
                    'Your account deletion request has been submitted. '
                    'An NSTP administrator will process it and you will be '
                    'notified once your account is deleted.'
                ),
            },
            status=status.HTTP_201_CREATED,
        )


class EditProfileAPIView(APIView):
    """
    Self-service profile edits (Profile screen) for staff roles.

    Matches the app's existing proof pattern (user_id + password, no bearer
    tokens) so every staff account can update their name / email / phone, plus
    the instructor department. Students are blocked outright - their profile
    fields are admin-governed.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        user_id = request.data.get('user_id')
        password = request.data.get('current_password') or ''

        if not user_id or not password:
            return Response(
                {'detail': 'user_id and current_password are required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            user = User.objects.get(id=user_id)
        except (User.DoesNotExist, ValueError):
            return Response({'detail': 'Account not found.'}, status=status.HTTP_404_NOT_FOUND)

        if not user.check_password(password):
            return Response(
                {'detail': 'Incorrect password. Your profile was not updated.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        role = (user.role or '').lower()
        if role == 'student':
            return Response(
                {'detail': 'Students cannot edit profile details.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        # Email is the app's recovery/notification address - it must stay unique.
        new_email = (request.data.get('email') or '').strip().lower()
        if new_email:
            taken = User.objects.exclude(pk=user.pk).filter(email__iexact=new_email).exists()
            if taken:
                return Response(
                    {'detail': 'That email is already in use by another account.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )

        serializer = EditProfileSerializer(user, data=request.data, partial=True)
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

        updated_user = serializer.save()

        response_data = UserSerializer(updated_user, context={'request': request}).data
        return Response(
            {
                'message': 'Profile updated successfully.',
                'user': response_data,
            },
            status=status.HTTP_200_OK,
        )


class ConsentAPIView(APIView):
    """
    Records that the user accepted the Privacy Policy and Terms & Conditions.

    New students consent at registration. Existing accounts (and staff created
    before this feature existed) use this endpoint from the one-time consent
    sheet shown after login. Matches the app's proof pattern (user_id +
    current password, no bearer tokens).
    """
    permission_classes = [AllowAny]

    def post(self, request):
        user_id = request.data.get('user_id')
        password = request.data.get('current_password') or ''

        if not user_id or not password:
            return Response(
                {'detail': 'user_id and current_password are required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            user = User.objects.get(id=user_id)
        except (User.DoesNotExist, ValueError):
            return Response({'detail': 'Account not found.'}, status=status.HTTP_404_NOT_FOUND)

        if not user.check_password(password):
            return Response(
                {'detail': 'Incorrect password. Please sign in again.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if user.accepted_terms_at is None:
            user.accepted_terms_at = timezone.now()
        if user.accepted_privacy_at is None:
            user.accepted_privacy_at = timezone.now()
        user.save(update_fields=['accepted_terms_at', 'accepted_privacy_at'])

        response_data = UserSerializer(user, context={'request': request}).data
        return Response(
            {
                'message': 'Thank you for accepting the Privacy Policy and Terms & Conditions.',
                'user': response_data,
            },
            status=status.HTTP_200_OK,
        )


def account_deletion_page(request):
    """
    Web page required by the Google Play data-safety declaration.

    Lets any user request account deletion without the app installed. The form
    verifies the email belongs to an existing account, then creates a pending
    AccountDeletionRequest for an NSTP admin to process.
    """
    if request.method == 'POST':
        email = (request.POST.get('email') or '').strip().lower()
        reason = (request.POST.get('reason') or '').strip()

        if not email:
            return render(request, 'attendance/account_deletion.html', {
                'error': 'Please enter the email address registered to your account.',
            })

        user = User.objects.filter(email__iexact=email).first()
        if user is None:
            # Neutral wording - do not leak which emails have accounts.
            return render(request, 'attendance/account_deletion.html', {
                'success': (
                    'If that email is registered, your account deletion request '
                    'has been submitted for review by an NSTP administrator. '
                    'You will be notified once it is processed.'
                ),
            })

        AccountDeletionRequest.objects.filter(
            user=user, status='pending'
        ).delete()
        AccountDeletionRequest.objects.create(
            user=user,
            email=user.email,
            reason=reason,
        )

        try:
            msg = EmailMultiAlternatives(
                'Account deletion request received - ISU NSTP Attendance',
                (
                    f"Hello {user.get_full_name() or user.username},\n\n"
                    f"We received your request to delete your ISU NSTP Attendance "
                    f"account and the data associated with it.\n\n"
                    f"Your request is now pending review by an NSTP administrator. "
                    f"You will receive another email once it has been processed.\n\n"
                    f"If you did not submit this request, please contact the NSTP "
                    f"office immediately.\n\n"
                    f"- ISU NSTP Support"
                ),
                getattr(settings, 'DEFAULT_FROM_EMAIL'),
                [user.email],
            )
            msg.send()
        except Exception as email_err:
            print(f"❌ Failed to send deletion ack email to {user.email}: {email_err}")

        return render(request, 'attendance/account_deletion.html', {
            'success': (
                'Your account deletion request has been submitted. '
                'An NSTP administrator will review it, and you will be '
                'notified once your account and associated data are deleted.'
            ),
        })

    return render(request, 'attendance/account_deletion.html')


