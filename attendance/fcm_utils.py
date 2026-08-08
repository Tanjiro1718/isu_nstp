# fcm_utils.py
import firebase_admin
from firebase_admin import credentials, messaging
import os
from django.conf import settings
from django.utils import timezone

# Initialize Firebase Admin SDK once
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CRED_PATH = os.path.join(settings.BASE_DIR, 'serviceAccountKey.json')

if not firebase_admin._apps:
    if os.path.exists(CRED_PATH):
        cred = credentials.Certificate(CRED_PATH)
        firebase_admin.initialize_app(cred)
        print("✅ Firebase Admin SDK initialized successfully.")
    else:
        print("⚠️ WARNING: serviceAccountKey.json not found! Push notifications will be disabled.")

def send_approval_notification(fcm_token: str, is_approved: bool, username: str):
    """
    Sends a FCM push notification when user status is changed.
    """
    if not firebase_admin._apps:
        print("Firebase is not initialized. Cannot send push notification.")
        return False

    if not fcm_token:
        print(f"No FCM token found for user {username}. Notification skipped.")
        return False

    if is_approved:
        title = "Account Approved! 🎉"
        body = f"Hello {username}, your ISU account has been approved. You can now log in."
    else:
        title = "Account Registration Status ❌"
        body = f"Hello {username}, your account registration request was not approved."

    message = messaging.Message(
        notification=messaging.Notification(
            title=title,
            body=body,
        ),
        data={
            "status": "approved" if is_approved else "rejected",
            "type": "account_status_update"
        },
        token=fcm_token,
    )

    try:
        response = messaging.send(message)
        print(f"Successfully sent FCM message: {response}")
        return True
    except Exception as e:
        print(f"Error sending FCM message to {username}: {e}")
        return False


def _urgent_android():
    """
    Android config for time-critical pushes.

    'high' priority is what lets a message wake a dozing device, so a reminder
    still lands when the phone is locked in someone's pocket or the app was
    swiped away. A phone that is genuinely powered off cannot receive anything;
    FCM holds the message and delivers it when the device comes back online,
    which is why the body always states the time rather than "in 5 minutes".
    """
    return messaging.AndroidConfig(
        priority='high',
        notification=messaging.AndroidNotification(
            channel_id='attendance_alerts',
            sound='default',
        ),
    )


def _urgent_apns():
    """iOS equivalent: priority 10 = deliver immediately, alert + sound."""
    return messaging.APNSConfig(
        headers={'apns-priority': '10'},
        payload=messaging.APNSPayload(
            aps=messaging.Aps(sound='default', content_available=True),
        ),
    )


def _broadcast_to_class(class_group, title, body, data):
    """
    Send one notification to every active student of a class.

    Returns the number of devices the message actually left the server for.
    """
    if not firebase_admin._apps:
        print("Firebase is not initialized. Cannot notify class.")
        return 0

    enrollments = class_group.enrollments.filter(
        status='active'
    ).select_related('student')

    tokens = [
        enrollment.student.fcm_token
        for enrollment in enrollments
        if enrollment.student.fcm_token
    ]

    if not tokens:
        print(f"No device tokens for class '{class_group.name}'. Nothing to send.")
        return 0

    payload = {k: str(v) for k, v in data.items()}

    sent = 0
    for token in tokens:
        message = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data=payload,
            token=token,
            android=_urgent_android(),
            apns=_urgent_apns(),
        )
        try:
            messaging.send(message)
            sent += 1
        except Exception as e:
            # One dead token should not stop the rest of the class.
            print(f"Error sending class push: {e}")

    print(f"Sent {sent}/{len(tokens)} pushes to '{class_group.name}'.")
    return sent


def notify_session_reminder(session):
    """
    Heads-up sent `reminder_minutes` before an activity opens.

    The body carries the absolute start time as well as the countdown: if the
    student's phone was off and FCM delivers this late, "starts at 9:00 AM"
    is still true where "starts in 5 minutes" would be a lie.
    """
    class_group = session.class_group
    if class_group is None:
        return 0

    minutes = session.reminder_minutes
    when = timezone.localtime(session.date_time).strftime('%I:%M %p')

    return _broadcast_to_class(
        class_group,
        title=f"Attendance starts in {minutes} min ⏰",
        body=(
            f"{session.title} ({class_group.name}) opens at {when}. "
            f"Get to the location and be ready to time in."
        ),
        data={
            'type': 'attendance_session_reminder',
            'session_id': session.id,
            'session_title': session.title,
            'class_id': class_group.id,
            'class_name': class_group.name,
            'starts_at': session.date_time.isoformat(),
            'reminder_minutes': minutes,
        },
    )


def notify_session_started(session):
    """
    Fired the moment the scheduled start time arrives - check-in is now open.
    """
    class_group = session.class_group
    if class_group is None:
        return 0

    closes = timezone.localtime(session.photo_deadline).strftime('%I:%M %p')

    return _broadcast_to_class(
        class_group,
        title=f"Attendance is now OPEN: {session.title}",
        body=(
            f"Time in now - the photo window closes at {closes}. "
            f"Tap to open the check-in map."
        ),
        data={
            'type': 'attendance_session_started',
            'session_id': session.id,
            'session_title': session.title,
            'class_id': class_group.id,
            'class_name': class_group.name,
            'target_latitude': session.target_latitude,
            'target_longitude': session.target_longitude,
            'radius_meters': session.radius_meters,
            'photo_deadline': session.photo_deadline.isoformat(),
        },
    )


def notify_check_out_open(session, records):
    """
    Tells every student still on standby that the instructor has opened the
    time-out window, so they can submit their final photo.
    """
    sent = 0
    for record in records:
        ok = _send_to_student(
            record.student,
            title=f"Time-out open: {session.title}",
            body="Your instructor opened time-out. Submit your photo to complete attendance.",
            data={
                'type': 'check_out_open',
                'session_id': str(session.id),
                'record_id': str(record.id),
            },
        )
        if ok:
            sent += 1
    print(f"Sent {sent}/{len(records)} check-out-open notifications.")
    return sent


def _send_to_student(student, title, body, data):
    """Single push to one StudentProfile. Returns True when it left the server."""
    if not firebase_admin._apps:
        print("Firebase is not initialized. Cannot send push notification.")
        return False

    token = getattr(student, 'fcm_token', None)
    if not token:
        print(f"No FCM token for {student}. Push skipped.")
        return False

    message = messaging.Message(
        notification=messaging.Notification(title=title, body=body),
        data={k: str(v) for k, v in data.items()},
        token=token,
    )
    try:
        messaging.send(message)
        return True
    except Exception as e:
        print(f"Error sending push to {student}: {e}")
        return False


def send_presence_check(check):
    """
    The random 'are you still on site?' prompt.

    The student must open the app and confirm with GPS before `expires_at`,
    otherwise the check is marked missed.
    """
    record = check.record
    minutes = record.session.presence_response_minutes

    return _send_to_student(
        record.student,
        title="Presence check - respond now ⏱️",
        body=(
            f"Confirm you are still at {record.session.title} "
            f"within {minutes} minutes or it will be marked missed."
        ),
        data={
            "type": "presence_check",
            "check_id": check.id,
            "record_id": record.id,
            "session_id": record.session_id,
            "session_title": record.session.title,
            "sequence": check.sequence,
            "expires_at": check.expires_at.isoformat() if check.expires_at else '',
            "response_minutes": minutes,
        },
    )


def send_presence_warning(record, missed_check):
    """First strike: they ignored a ping but can still save their attendance."""
    return _send_to_student(
        record.student,
        title="⚠️ Warning: presence check missed",
        body=(
            "You did not respond to the presence check. Respond to the next one "
            "or you will lose your attendance time-out for this activity."
        ),
        data={
            "type": "presence_warning",
            "record_id": record.id,
            "session_id": record.session_id,
            "missed_check_id": missed_check.id,
            "missed_checks": record.missed_checks,
        },
    )


def send_change_password_code(user, code):
    """
    Push the change-password verification code to whichever device the user
    last registered. Works for every role, not just students, because it reads
    User.push_token rather than StudentProfile.fcm_token.
    """
    if not firebase_admin._apps:
        print("Firebase is not initialized. Cannot send push.")
        return False

    token = getattr(user, 'push_token', None)
    if not token:
        print(f"No device token for {user.username}; change-password push skipped.")
        return False

    message = messaging.Message(
        notification=messaging.Notification(
            title="Confirm your password change 🔐",
            body=(
                f"Hello {user.username}, your confirmation code is {code}. "
                "It expires in 10 minutes. If this wasn't you, do not use it."
            ),
        ),
        data={
            "type": "change_password_code",
            "code": str(code),
        },
        token=token,
    )

    try:
        response = messaging.send(message)
        print(f"Change-password FCM sent to {user.username}: {response}")
        return True
    except Exception as e:
        print(f"Error sending change-password FCM to {user.username}: {e}")
        return False


def send_password_changed_alert(user):
    """
    Security notice after the password actually changes, so a hijacked account
    surfaces immediately instead of silently.
    """
    if not firebase_admin._apps:
        return False

    token = getattr(user, 'push_token', None)
    if not token:
        return False

    message = messaging.Message(
        notification=messaging.Notification(
            title="Your password was changed ✅",
            body=(
                "Your ISU NSTP password was just updated. "
                "If this wasn't you, contact the NSTP office immediately."
            ),
        ),
        data={"type": "password_changed"},
        token=token,
    )

    try:
        messaging.send(message)
        return True
    except Exception as e:
        print(f"Error sending password-changed alert to {user.username}: {e}")
        return False


def send_password_reset_code(fcm_token, code, username):
    """
    Push a 6-digit password reset verification code to the user's device.
    Falls back to email when no FCM token is present (handled by the caller).
    """
    if not firebase_admin._apps:
        print("Firebase is not initialized. Cannot send push.")
        return False
    if not fcm_token:
        return False

    message = messaging.Message(
        notification=messaging.Notification(
            title="Password Reset Code 🔐",
            body=f"Hello {username}, your verification code is: {code}. "
                  "It expires in 10 minutes.",
        ),
        data={
            "type": "password_reset_code",
            "code": code,
        },
        token=fcm_token,
    )

    try:
        response = messaging.send(message)
        print(f"Password-reset FCM sent to {username}: {response}")
        return True
    except Exception as e:
        print(f"Error sending password-reset FCM to {username}: {e}")
        return False


def send_excuse_submitted(excuse):
    """
    Tell the instructor an excuse letter is waiting for review.

    Aimed at User.push_token (not StudentProfile.fcm_token) because the
    recipient here is staff, not a student.
    """
    if not firebase_admin._apps:
        print("Firebase is not initialized. Cannot send push.")
        return False

    instructor = excuse.session.instructor
    token = getattr(instructor, 'push_token', None)
    if not token:
        print(f"No device token for {instructor.username}; excuse push skipped.")
        return False

    student_name = excuse.student.user.get_full_name() or excuse.student.user.username
    message = messaging.Message(
        notification=messaging.Notification(
            title="New excuse letter 📩",
            body=(
                f"{student_name} submitted an excuse for {excuse.session.title}. "
                "Tap to review it."
            ),
        ),
        data={
            "type": "excuse_submitted",
            "excuse_id": str(excuse.id),
            "session_id": str(excuse.session_id),
            "kind": excuse.kind,
        },
        token=token,
    )

    try:
        messaging.send(message)
        return True
    except Exception as e:
        print(f"Error sending excuse push to {instructor.username}: {e}")
        return False


def send_excuse_reviewed(excuse):
    """Tell the student whether their excuse was approved or rejected."""
    approved = excuse.status == 'approved'
    note = (excuse.response_note or '').strip()

    if approved:
        title = "Excuse approved ✅"
        body = f"Your excuse for {excuse.session.title} was approved."
    else:
        title = "Excuse rejected ❌"
        body = f"Your excuse for {excuse.session.title} was not approved."
    if note:
        body = f"{body} Note: {note}"

    return _send_to_student(
        excuse.student,
        title=title,
        body=body,
        data={
            "type": "excuse_reviewed",
            "excuse_id": excuse.id,
            "session_id": excuse.session_id,
            "status": excuse.status,
        },
    )


def send_presence_failed(record):
    """Second strike: check-out is now blocked for this activity."""
    return _send_to_student(
        record.student,
        title="❌ Attendance verification failed",
        body=(
            "You ignored repeated presence checks, so you can no longer submit "
            "a time-out photo for this activity. Please see your instructor."
        ),
        data={
            "type": "presence_failed",
            "record_id": record.id,
            "session_id": record.session_id,
            "missed_checks": record.missed_checks,
        },
    )
