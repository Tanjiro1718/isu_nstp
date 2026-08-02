import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import '../../config/api_config.dart';
import '../../models/user_model.dart'; // Import your user model!
import '../../widgets/location_guidance_card.dart';

class StudentCheckInScreen extends StatefulWidget {
  final UserModel user; // Added this so the screen knows who is checking in
  final int sessionId;
  final double targetLat;
  final double targetLng;
  final int allowedRadiusMeters;

  /// Absolute moment the photo window shuts. Passing null hides the countdown,
  /// which keeps older callers working unchanged.
  final DateTime? photoDeadline;

  const StudentCheckInScreen({
    super.key,
    required this.user,
    required this.sessionId,
    required this.targetLat,
    required this.targetLng,
    required this.allowedRadiusMeters,
    this.photoDeadline,
  });

  @override
  _StudentCheckInScreenState createState() => _StudentCheckInScreenState();
}

class _StudentCheckInScreenState extends State<StudentCheckInScreen> {
  CameraController? _cameraController;
  XFile? _capturedSelfie;
  Position? _currentPosition;
  bool _isLoading = false;
  double _distanceFromTarget = -1.0;
  String _statusMessage = "Ready for check-in";

  // --- Photo submission window ---
  Timer? _countdownTimer;
  Duration _timeLeft = Duration.zero;

  // Keeps the walking guidance live while the student is on their way over.
  Timer? _locationPoller;

  bool get _hasDeadline => widget.photoDeadline != null;
  bool get _windowExpired => _hasDeadline && _timeLeft <= Duration.zero;

  @override
  void initState() {
    super.initState();
    // Start our sequence so they don't trip over each other
    _initializeSequentially();
    _startCountdown();
    _startLocationUpdates();
  }

  /// Re-reads the GPS every 10 seconds so the arrow and the remaining distance
  /// update while the student walks, instead of only on a manual refresh.
  void _startLocationUpdates() {
    _locationPoller = Timer.periodic(const Duration(seconds: 10), (_) {
      // Skip while a check-in is mid-flight so we don't fight over _isLoading.
      if (!_isLoading) _determinePosition(silent: true);
    });
  }

  /// Ticks once a second so the student can see how long they have left to
  /// submit their photo before the window closes.
  void _startCountdown() {
    if (!_hasDeadline) return;

    void tick() {
      final remaining = widget.photoDeadline!.difference(DateTime.now());
      if (!mounted) return;
      setState(() {
        _timeLeft = remaining.isNegative ? Duration.zero : remaining;
      });
      if (remaining.isNegative) {
        _countdownTimer?.cancel();
      }
    }

    tick();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  String get _formattedTimeLeft {
    final minutes = _timeLeft.inMinutes.toString().padLeft(2, '0');
    final seconds = (_timeLeft.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  // A helper method to run camera, wait for it to finish, then run GPS
  Future<void> _initializeSequentially() async {
    // 1. First, set up the camera (and show its permission prompt if needed)
    await _initializeCamera();

    // 2. Only after the camera is fully ready, check the GPS location (and show its prompt)
    await _determinePosition();
  }

  // Initialize front camera for selfie verification
  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _statusMessage = "Camera error: $e");
    }
  }

  // Get current device GPS location
  //
  // [silent] is used by the background poller: it refreshes the coordinates
  // without flipping the full-screen spinner on every tick.
  Future<void> _determinePosition({bool silent = false}) async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(
        () =>
            _statusMessage = "Please enable location services on your device.",
      );
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => _statusMessage = "Location permissions are denied.");
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(
        () => _statusMessage = "Location permissions are permanently denied.",
      );
      return;
    }

    if (!silent) setState(() => _isLoading = true);
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy:
            LocationAccuracy.high, // Updated for newer geolocator syntax
      );

      // Compute geographic distance in meters between student and geofence target center
      double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        widget.targetLat,
        widget.targetLng,
      );

      if (!mounted) return;
      setState(() {
        _currentPosition = position;
        _distanceFromTarget = distance;
        if (!silent) _isLoading = false;
        if (distance > widget.allowedRadiusMeters) {
          _statusMessage =
              "Too far to check in. Follow the directions below.";
        } else {
          _statusMessage =
              "Location verified. You are within range (${distance.toStringAsFixed(1)}m).";
        }
      });
    } catch (e) {
      if (!mounted) return;
      // A failed background poll should not wipe out working guidance.
      if (silent) return;
      setState(() {
        _isLoading = false;
        _statusMessage = "Error fetching location: $e";
      });
    }
  }

  // Handle snapping photo and transmitting package to Django backend
  Future<void> _processCheckIn() async {
    if (_currentPosition == null || _cameraController == null) {
      setState(
        () => _statusMessage =
            "Cannot check in. Location or Camera data missing.",
      );
      return;
    }

    if (_distanceFromTarget > widget.allowedRadiusMeters) {
      setState(
        () => _statusMessage =
            "Check-in blocked: Outside the required perimeter.",
      );
      return;
    }

    if (_windowExpired) {
      setState(
        () => _statusMessage =
            "The photo window has closed. Ask your instructor to record you manually.",
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Step 1: Snap verification selfie
      final XFile image = await _cameraController!.takePicture();
      setState(() => _capturedSelfie = image);

      // Step 2: Prepare multipart payload data package for Django API
      var request = http.MultipartRequest(
        "POST",
        Uri.parse(ApiConfig.attendanceCheckInUrl),
      );

      // Include metadata headers/fields
      request.fields['session_id'] = widget.sessionId.toString();
      request.fields['student_id'] = widget.user.id
          .toString(); // Tell Django WHICH student is checking in
      request.fields['latitude'] = _currentPosition!.latitude.toString();
      request.fields['longitude'] = _currentPosition!.longitude.toString();

      // TODO: If Django's [IsAuthenticated] blocks this, we will need to pass your actual JWT token here later.
      // request.headers['Authorization'] = 'Bearer YOUR_ACTUAL_TOKEN';

      // Attach file element binary stream
      request.files.add(
        await http.MultipartFile.fromPath('selfie', File(image.path).path),
      );

      var response = await request.send();

      final responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200 || response.statusCode == 201) {
        setState(() => _statusMessage = "Attendance Checked In Successfully!");
        if (mounted) {
          // Surface the presence-check warning so it is not a surprise later.
          String note = '';
          try {
            note = (jsonDecode(responseBody)['presence_note'] as String?) ?? '';
          } catch (_) {
            // A non-JSON success body is not worth failing the check-in over.
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                note.isNotEmpty ? 'Time-in recorded. $note' : 'Time-in Recorded Successfully!',
              ),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 5),
            ),
          );
          Navigator.pop(context, true); // Go back to dashboard after success!
        }
      } else {
        // The backend explains exactly why (window closed, already timed in...).
        String serverMessage = "Error Code: ${response.statusCode}";
        try {
          final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
          serverMessage = (decoded['message'] ?? decoded['error'] ?? serverMessage).toString();
        } catch (_) {
          // Keep the status-code fallback.
        }
        setState(() => _statusMessage = serverMessage);
      }
    } catch (e) {
      setState(() => _statusMessage = "Network transaction failed: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _locationPoller?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isWithinBounds =
        _distanceFromTarget >= 0 &&
        _distanceFromTarget <= widget.allowedRadiusMeters;

    return Scaffold(
      appBar: AppBar(
        title: const Text("ISU-NSTP GPS Check-In"),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16.0),
              key: UniqueKey(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Camera Preview Container Box
                  Expanded(
                    flex: 3,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child:
                          _cameraController != null &&
                              _cameraController!.value.isInitialized
                          ? CameraPreview(_cameraController!)
                          : const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // The guidance map makes this section taller than a small
                  // phone can fit, so let everything below the camera scroll.
                  Expanded(
                    flex: 4,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                  // Countdown for the photo submission window.
                  if (_hasDeadline) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 16,
                      ),
                      decoration: BoxDecoration(
                        color: _windowExpired
                            ? Colors.red.shade50
                            : (_timeLeft.inSeconds <= 60
                                  ? Colors.orange.shade50
                                  : Colors.blue.shade50),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _windowExpired
                              ? Colors.red.shade200
                              : (_timeLeft.inSeconds <= 60
                                    ? Colors.orange.shade300
                                    : Colors.blue.shade200),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _windowExpired ? Icons.timer_off : Icons.timer,
                            size: 20,
                            color: _windowExpired
                                ? Colors.red.shade700
                                : (_timeLeft.inSeconds <= 60
                                      ? Colors.orange.shade800
                                      : Colors.blue.shade700),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _windowExpired
                                  ? "Photo window closed"
                                  : "Submit your photo within $_formattedTimeLeft",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _windowExpired
                                    ? Colors.red.shade700
                                    : (_timeLeft.inSeconds <= 60
                                          ? Colors.orange.shade900
                                          : Colors.blue.shade900),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Status and Feedback Card Panel Area
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          Text(
                            _statusMessage,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: isWithinBounds ? Colors.green : Colors.red,
                              fontSize: 16,
                            ),
                          ),
                          const Divider(height: 20),
                          // Which way to walk, how far is left, and a map.
                          LocationGuidanceCard(
                            targetLat: widget.targetLat,
                            targetLng: widget.targetLng,
                            allowedRadiusMeters: widget.allowedRadiusMeters,
                            currentLat: _currentPosition?.latitude,
                            currentLng: _currentPosition?.longitude,
                            distanceMeters: _distanceFromTarget,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Action buttons
                  ElevatedButton.icon(
                    onPressed: _determinePosition,
                    icon: const Icon(Icons.refresh),
                    label: const Text("Refresh GPS Position"),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    onPressed: (isWithinBounds && !_windowExpired)
                        ? _processCheckIn
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: (isWithinBounds && !_windowExpired)
                          ? Colors.green
                          : Colors.grey,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      _windowExpired
                          ? "Photo Window Closed"
                          : "Confirm & Submit Attendance",
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
