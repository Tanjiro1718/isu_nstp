import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import 'models/user_model.dart';
import 'screens/admin/admin_dashboard.dart';
import 'screens/director/director_dashboard.dart';
import 'screens/instructor/instructor_dashboard.dart';
import 'screens/login_screen.dart';
import 'screens/student/student_dashboard.dart';
import 'config/api_config.dart';
import 'services/device_token_service.dart';
import 'services/session_service.dart';

// Adjust path according to where notification_service.dart is located in your lib/ folder
import 'services/notification_service.dart'; 

void main() async {
  // 1. Ensure Flutter bindings are initialized first
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Initialize Firebase
  await Firebase.initializeApp(
    // If you configured Firebase CLI, uncomment the line below:
    // options: DefaultFirebaseOptions.currentPlatform, 
  );

  // 3. Initialize Notification Service (permissions, FCM listeners, background handlers)
  await NotificationService().initialize();

  // 4. Nudge the backend out of Render's idle cold start BEFORE the student
  //    needs it, so the very first register/login call isn't the slow one.
  _warmBackend();

  // 5. Run the App
  runApp(const IsuNstpApp());
}

/// Free Render instances go to sleep after ~15 min without traffic and pay a
/// long cold boot on the next request. Fire a tiny, no-auth probe on launch so
/// the student's first submit returns in normal time. Fire-and-forget - it
/// must never delay or break startup.
Future<void> _warmBackend() async {
  try {
    await http
        .get(Uri.parse('${ApiConfig.baseUrl}/api/health/'))
        .timeout(const Duration(seconds: 10));
  } catch (_) {
    // Warm-up is best-effort; the app works fine even if this fails.
  }
}

class IsuNstpApp extends StatelessWidget {
  const IsuNstpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ISU NSTP Attendance System',
      theme: ThemeData(primarySwatch: Colors.green),
      home: const _SessionGate(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// Decides the first screen: the saved dashboard, or login.
///
/// Reading preferences is async, so a brief splash is unavoidable. Routing here
/// rather than inside LoginScreen keeps the login form free of "am I already
/// signed in?" logic and avoids a visible flash of the login page.
class _SessionGate extends StatefulWidget {
  const _SessionGate();

  @override
  State<_SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<_SessionGate> {
  static const Color _isuGreen = Color(0xFF006837);

  bool _checking = true;
  UserModel? _user;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final user = await SessionService.loadUser();

    // Skipping login means the device token would never be refreshed, so do it
    // here as well. Fire-and-forget - it must not delay the first frame.
    if (user != null) {
      DeviceTokenService.register(user.id);
    }

    if (!mounted) return;
    setState(() {
      _user = user;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: _isuGreen),
              SizedBox(height: 16),
              Text(
                'ISU NSTP Attendance',
                style: TextStyle(
                  color: _isuGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final user = _user;
    if (user == null) return const LoginScreen();

    // An unrecognised role should not strand the user on a blank screen.
    switch (user.role.toLowerCase()) {
      case 'admin':
        return AdminDashboard(user: user);
      case 'instructor':
        return InstructorDashboard(user: user);
      case 'director':
        return DirectorDashboard(user: user);
      case 'student':
        return StudentDashboard(user: user);
      default:
        return const LoginScreen();
    }
  }
}
