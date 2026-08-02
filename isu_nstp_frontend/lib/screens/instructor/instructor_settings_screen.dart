import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../config/api_config.dart';
import '../../models/class_model.dart';
import '../../models/user_model.dart';
import '../../services/class_service.dart';

class InstructorSettingsScreen extends StatefulWidget {
  final UserModel user;
  const InstructorSettingsScreen({super.key, required this.user});

  @override
  State<InstructorSettingsScreen> createState() =>
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

  // The class this geofence session belongs to.
  List<ClassModel> _classes = [];
  int? _selectedClassId;
  bool _isLoadingClasses = true;
  String? _classLoadError;

  final String apiUrl = ApiConfig.systemSettingsUrl;
  final String sessionUrl = ApiConfig.currentSessionUrl;

  @override
  void initState() {
    super.initState();
    _loadCurrentSettings();
    _loadClasses();
  }

  Future<void> _loadClasses() async {
    try {
      final classes = await ClassService.fetchInstructorClasses(widget.user.id);
      if (!mounted) return;
      setState(() {
        _classes = classes;
        // Preselect when there is only one class, so the common case is 1 tap.
        if (classes.length == 1) _selectedClassId = classes.first.id;
        _isLoadingClasses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _classLoadError = e.toString();
        _isLoadingClasses = false;
      });
    }
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

    // Without a class the session would be invisible to every student.
    if (_selectedClassId == null) {
      _showSnackBar(
        _classes.isEmpty
            ? 'Create a class first, then assign this location to it.'
            : 'Please choose which class this session is for.',
        Colors.red,
      );
      return;
    }

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
        final className = _classes
            .firstWhere((c) => c.id == _selectedClassId)
            .name;
        _showSnackBar('Session started for $className!', Colors.green);
      } else {
        _showSnackBar('Failed updating class settings.', Colors.red);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Network error occurred: $e', Colors.red);
    }
  }

  Future<void> _createAttendanceSession() async {
    final selectedClass = _classes.firstWhere((c) => c.id == _selectedClassId);

    final response = await http.post(
      Uri.parse(sessionUrl),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'instructor': widget.user.id,
        'title': '${selectedClass.name} Attendance',
        'date_time': DateTime.now().toUtc().toIso8601String(),
        'target_latitude': double.parse(_latController.text),
        'target_longitude': double.parse(_lngController.text),
        'radius_meters': int.parse(_radiusController.text),
        // Ties the geofence to a class so only its members can check in.
        'class_group': _selectedClassId,
      }),
    );

    if (response.statusCode != 201) {
      throw Exception('Failed creating attendance session: ${response.body}');
    }
  }

  /// Dropdown of the instructor's classes; the geofence is saved against it.
  Widget _buildClassPicker() {
    if (_isLoadingClasses) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_classLoadError != null) {
      return _buildClassNotice(
        color: Colors.red,
        icon: Icons.cloud_off,
        text: 'Could not load your classes: $_classLoadError',
        onRetry: () {
          setState(() {
            _isLoadingClasses = true;
            _classLoadError = null;
          });
          _loadClasses();
        },
      );
    }

    if (_classes.isEmpty) {
      return _buildClassNotice(
        color: Colors.orange,
        icon: Icons.info_outline,
        text:
            'You have no classes yet. Create one in "My Classes" first, then '
            'come back to assign this attendance location to it.',
      );
    }

    return DropdownButtonFormField<int>(
      initialValue: _selectedClassId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Assign this session to',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.class_),
      ),
      hint: const Text('Select a class'),
      items: _classes.map((c) {
        final label = [
          c.name,
          if (c.sectionCode.isNotEmpty) c.sectionCode,
        ].join(' - ');
        return DropdownMenuItem(
          value: c.id,
          child: Text(
            '$label  (${c.studentCount} students)',
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
      onChanged: (val) => setState(() => _selectedClassId = val),
      validator: (val) => val == null ? 'Please choose a class' : null,
    );
  }

  Widget _buildClassNotice({
    required Color color,
    required IconData icon,
    required String text,
    VoidCallback? onRetry,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color)),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
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
                      "Which Class?",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    const Text(
                      "Only students enrolled in the class you pick will see this session.",
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    _buildClassPicker(),
                    const SizedBox(height: 32),

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
