import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'screens/login_screen.dart';

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

  // 4. Run the App
  runApp(const IsuNstpApp());
}

class IsuNstpApp extends StatelessWidget {
  const IsuNstpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ISU NSTP Attendance System',
      theme: ThemeData(primarySwatch: Colors.green),
      home: const LoginScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center, // Fixed syntax error here (.center -> MainAxisAlignment.center)
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}