import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import '../../config/api_config.dart';
import '../../models/user_model.dart'; // Import your user model!

class StudentCheckInScreen extends StatefulWidget {
  final UserModel user; // Added this so the screen knows who is checking in
  final int sessionId;
  final double targetLat;
  final double targetLng;
  final int allowedRadiusMeters;

  const StudentCheckInScreen({
    super.key,
    required this.user,
    required this.sessionId,
    required this.targetLat,
    required this.targetLng,
    required this.allowedRadiusMeters,
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

  @override
  void initState() {
    super.initState();
    // Start our sequence so they don't trip over each other
    _initializeSequentially();
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
  Future<void> _determinePosition() async {
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

    setState(() => _isLoading = true);
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

      setState(() {
        _currentPosition = position;
        _distanceFromTarget = distance;
        _isLoading = false;
        if (distance > widget.allowedRadiusMeters) {
          _statusMessage =
              "Out of Bounds! You are ${distance.toStringAsFixed(1)}m away.";
        } else {
          _statusMessage =
              "Location verified. You are within range (${distance.toStringAsFixed(1)}m).";
        }
      });
    } catch (e) {
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

      if (response.statusCode == 200 || response.statusCode == 201) {
        setState(() => _statusMessage = "Attendance Checked In Successfully!");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Time-in Recorded Successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context); // Go back to dashboard after success!
        }
      } else {
        setState(
          () => _statusMessage =
              "Server verification failed. Error Code: ${response.statusCode}",
        );
      }
    } catch (e) {
      setState(() => _statusMessage = "Network transaction failed: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
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
                          Text(
                            "Latitude: ${_currentPosition == null ? 'Searching...' : _currentPosition!.latitude.toStringAsFixed(6)}",
                          ),
                          Text(
                            "Longitude: ${_currentPosition == null ? 'Searching...' : _currentPosition!.longitude.toStringAsFixed(6)}",
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
                    onPressed: isWithinBounds ? _processCheckIn : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isWithinBounds
                          ? Colors.green
                          : Colors.grey,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      "Confirm & Submit Attendance",
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
