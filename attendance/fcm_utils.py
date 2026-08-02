# fcm_utils.py
import firebase_admin
from firebase_admin import credentials, messaging
import os
from django.conf import settings

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


def notify_class_of_session(class_group, session):
    """
    Pushes a notification to every active student of `class_group` when the
    instructor opens a new attendance session.

    The payload carries the session id and geofence coordinates so the app can
    deep-link straight into the check-in map.
    """
    if not firebase_admin._apps:
        print("Firebase is not initialized. Cannot notify class.")
        return 0

    # Only active members with a registered device get a push.
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

    when = session.date_time.strftime('%b %d, %I:%M %p')
    title = f"Attendance open: {session.title}"
    body = (
        f"{class_group.name} • {when}. "
        f"Tap to see the check-in location on the map."
    )

    # Data values must all be strings for FCM.
    data = {
        "type": "attendance_session_created",
        "session_id": str(session.id),
        "session_title": session.title,
        "class_id": str(class_group.id),
        "class_name": class_group.name,
        "target_latitude": str(session.target_latitude),
        "target_longitude": str(session.target_longitude),
        "radius_meters": str(session.radius_meters),
    }

    sent = 0
    for token in tokens:
        message = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data=data,
            token=token,
        )
        try:
            messaging.send(message)
            sent += 1
        except Exception as e:
            # One dead token should not stop the rest of the class.
            print(f"Error sending session push: {e}")

    print(f"Sent {sent}/{len(tokens)} session notifications for '{class_group.name}'.")
    return sent


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
