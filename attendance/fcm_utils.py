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