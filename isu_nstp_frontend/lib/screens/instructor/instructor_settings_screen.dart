import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../config/api_config.dart';
import '../../models/user_model.dart';

class InstructorSettingsScreen extends StatefulWidget {
  final UserModel user;
  const InstructorSettingsScreen({super.key, required this.user});

  @override
  _InstructorSettingsScreenState createState() =>
      _InstructorSettingsScreenState();
}

class _InstructorSettingsScreenState extends State<InstructorSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = true;

  final _latController = TextEditingController();
  final _lngController = TextEditingController();
  final _radiusController = TextEditingController();
  final _ayController = TextEditingController();
  String _selectedSemester = '1st Semester';

  LatLng? _pickedLocation;
  final MapController _mapController = MapController();

  final String apiUrl = ApiConfig.systemSettingsUrl;
  final String sessionUrl = ApiConfig.currentSessionUrl;

  @override
  void initState() {
    super.initState();
    _loadCurrentSettings();
  }

  Future<void> _loadCurrentSettings() async {
    try {
      final response = await http.get(Uri.parse(apiUrl));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          double lat = data['target_latitude'] ?? 16.9360;
          double lng = data['target_longitude'] ?? 121.7730;

          _latController.text = lat.toString();
          _lngController.text = lng.toString();
          _radiusController.text = data['allowed_radius_meters'].toString();
          _ayController.text = data['academic_year'];
          _selectedSemester = data['semester'] ?? '1st Semester';

          _pickedLocation = LatLng(lat, lng);
          _isLoading = false;
        });
      } else {
        _showSnackBar('Failed to load class parameters.', Colors.red);
      }
    } catch (e) {
      _showSnackBar('Network connection error: $e', Colors.red);
    }
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    try {
      final response = await http.put(
        Uri.parse(apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'target_latitude': double.parse(_latController.text),
          'target_longitude': double.parse(_lngController.text),
          'allowed_radius_meters': int.parse(_radiusController.text),
          'academic_year': _ayController.text,
          'semester': _selectedSemester,
        }),
      );

      setState(() => _isLoading = false);

      if (response.statusCode == 200) {
        await _createAttendanceSession();
        _showSnackBar('Attendance session started successfully!', Colors.green);
      } else {
        _showSnackBar('Failed updating class settings.', Colors.red);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Network error occurred: $e', Colors.red);
    }
  }

  Future<void> _createAttendanceSession() async {
    final response = await http.post(
      Uri.parse(sessionUrl),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'instructor': widget.user.id,
        'title': 'NSTP Attendance Session',
        'date_time': DateTime.now().toUtc().toIso8601String(),
        'target_latitude': double.parse(_latController.text),
        'target_longitude': double.parse(_lngController.text),
        'radius_meters': int.parse(_radiusController.text),
      }),
    );

    if (response.statusCode != 201) {
      throw Exception('Failed creating attendance session: ${response.body}');
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Class Location Setup"),
        backgroundColor: Colors.blue.shade800, // Instructor Theme Color
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(20.0),
              child: Form(
                key: _formKey,
                child: ListView(
                  children: [
                    const Text(
                      "Set Meeting Location",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    const Text(
                      "Tap the map to set where students should check in today.",
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),

                    Container(
                      height: 300,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Colors.grey.shade400,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: FlutterMap(
                          mapController: _mapController,
                          options: MapOptions(
                            initialCenter:
                                _pickedLocation ?? LatLng(16.9360, 121.7730),
                            initialZoom: 14.0,
                            onTap: (tapPosition, point) {
                              setState(() {
                                _pickedLocation = point;
                                _latController.text = point.latitude
                                    .toStringAsFixed(6);
                                _lngController.text = point.longitude
                                    .toStringAsFixed(6);
                              });
                            },
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName:
                                  'ph.edu.isu.nstp.attendanceapp',
                            ),
                            if (_pickedLocation != null)
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    point: _pickedLocation!,
                                    width: 40,
                                    height: 40,
                                    child: const Icon(
                                      Icons.location_on,
                                      color: Colors.red,
                                      size: 40,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _latController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Latitude',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) => v!.isEmpty ? 'Required' : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _lngController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Longitude',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) => v!.isEmpty ? 'Required' : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _radiusController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Allowed Check-in Radius (Meters)',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => v!.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 32),
                    const Text(
                      "Academic Schedule",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    const Divider(),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _ayController,
                      decoration: const InputDecoration(
                        labelText: 'Academic Year',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => v!.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedSemester,
                      decoration: const InputDecoration(
                        labelText: 'Semester',
                        border: OutlineInputBorder(),
                      ),
                      items: ['1st Semester', '2nd Semester', 'Summer']
                          .map(
                            (s) => DropdownMenuItem(value: s, child: Text(s)),
                          )
                          .toList(),
                      onChanged: (val) =>
                          setState(() => _selectedSemester = val!),
                    ),
                    const SizedBox(height: 40),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade800,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: _saveSettings,
                      child: const Text(
                        "Save Class Location & Start Session",
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
