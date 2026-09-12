import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../config/api_config.dart';
import '../../config/campus_config.dart';
import '../../models/class_model.dart';
import '../../models/user_model.dart';
import '../../services/class_service.dart';

class InstructorSettingsScreen extends StatefulWidget {
  final UserModel user;
  /// True when the screen is shown as a tab inside a dashboard. It then drops
  /// its own AppBar so the parent's bar is the only one on screen.
  final bool embedded;

  const InstructorSettingsScreen({
    super.key,
    required this.user,
    this.embedded = false,
  });

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

  // When the activity actually begins. Null means "start now" - the common
  // case - so the instructor never has to touch a date picker to run a
  // session on the spot.
  DateTime? _scheduledStart;

  // How far ahead of the start the class gets the heads-up push.
  int _reminderMinutes = 5;

  // What the class will actually do. Cleaning keeps the random presence
  // pings; lecturing turns them off and relies on check-in/time-out only.
  _SessionType _sessionType = _SessionType.cleaning;

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
          final double lat =
              (data['target_latitude'] as num?)?.toDouble() ??
                  CampusConfig.center.latitude;
          final double lng =
              (data['target_longitude'] as num?)?.toDouble() ??
                  CampusConfig.center.longitude;

          // Settings saved before the campus restriction existed could point
          // anywhere. Snapping back to the centre keeps the marker inside the
          // map's own bounds - otherwise it would sit somewhere the camera is
          // no longer allowed to travel to.
          final location = CampusConfig.clampToCampus(LatLng(lat, lng));

          _latController.text = location.latitude.toStringAsFixed(6);
          _lngController.text = location.longitude.toStringAsFixed(6);
          _radiusController.text = data['allowed_radius_meters'].toString();
          _ayController.text = data['academic_year'];
          _selectedSemester = data['semester'] ?? '1st Semester';

          _pickedLocation = location;
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
        // Always sent in UTC; the server renders it back in local time.
        'date_time': (_scheduledStart ?? DateTime.now())
            .toUtc()
            .toIso8601String(),
        'reminder_minutes': _reminderMinutes,
        // Lecturing does check-in/time-out only, so no random presence pings.
        'presence_check_count':
            _sessionType == _SessionType.lecturing ? 0 : 2,
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

  /// Human-readable summary of when the activity opens.
  String get _startLabel {
    if (_scheduledStart == null) return 'Starts immediately';

    final d = _scheduledStart!;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    final period = d.hour < 12 ? 'AM' : 'PM';
    return '${months[d.month - 1]} ${d.day}, ${d.year} at $hour12:$minute $period';
  }

  /// Date then time. Leaves the schedule untouched if either step is
  /// cancelled, so a half-finished pick cannot set a nonsense start.
  Future<void> _pickStartDateTime() async {
    final now = DateTime.now();
    final base = _scheduledStart ?? now.add(const Duration(minutes: 30));

    final date = await showDatePicker(
      context: context,
      initialDate: base.isBefore(now) ? now : base,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null || !mounted) return;

    final chosen = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );

    // A start in the past would open check-in instantly and fire the reminder
    // for a moment that has already gone by.
    if (chosen.isBefore(now)) {
      _showSnackBar('Pick a time in the future.', Colors.red);
      return;
    }

    setState(() => _scheduledStart = chosen);
  }

  /// Start time + how early the class is warned.
  Widget _buildScheduleSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "When Does It Start?",
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.blue,
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 16, color: Colors.grey.shade600),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                "Students are notified when the activity opens, and again the "
                "set minutes beforehand. Nobody can time in before the start.",
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        InkWell(
          onTap: _pickStartDateTime,
          borderRadius: BorderRadius.circular(8),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Start time',
              border: const OutlineInputBorder(),
              // Only offer "clear" once a schedule is actually set.
              suffixIcon: _scheduledStart == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Start immediately instead',
                      onPressed: () => setState(() => _scheduledStart = null),
                    ),
            ),
            child: Text(_startLabel),
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          initialValue: _reminderMinutes,
          decoration: const InputDecoration(
            labelText: 'Remind students before start',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 0, child: Text('No advance reminder')),
            DropdownMenuItem(value: 5, child: Text('5 minutes before')),
            DropdownMenuItem(value: 10, child: Text('10 minutes before')),
            DropdownMenuItem(value: 15, child: Text('15 minutes before')),
            DropdownMenuItem(value: 30, child: Text('30 minutes before')),
            DropdownMenuItem(value: 60, child: Text('1 hour before')),
          ],
          onChanged: (val) => setState(() => _reminderMinutes = val ?? 5),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<_SessionType>(
          initialValue: _sessionType,
          decoration: const InputDecoration(
            labelText: 'Session type',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: _SessionType.cleaning,
              child: Text('Cleaning - presence checks on'),
            ),
            DropdownMenuItem(
              value: _SessionType.lecturing,
              child: Text('Lecturing - check-in & time-out only'),
            ),
          ],
          onChanged: (val) => setState(() => _sessionType = val ?? _SessionType.cleaning),
          selectedItemBuilder: (context) => const [
            Text('Cleaning'),
            Text('Lecturing'),
          ],
        ),
        if (_sessionType == _SessionType.lecturing)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'No random presence checks for this session. Students just '
                    'check in and check out.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
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

  /// Places the meeting point, refusing anything off campus.
  ///
  /// The camera constraint already stops the instructor panning away, but the
  /// visible area is a rectangle around the bounds - at the corners a tap can
  /// still land just outside. Checking the point itself is what actually
  /// enforces the rule.
  void _handleMapTap(TapPosition tapPosition, LatLng point) {
    if (!CampusConfig.contains(point)) {
      _showSnackBar(CampusConfig.outsideMessage, Colors.red);
      return;
    }

    setState(() {
      _pickedLocation = point;
      _latController.text = point.latitude.toStringAsFixed(6);
      _lngController.text = point.longitude.toStringAsFixed(6);
    });
  }

  /// Validates a hand-typed coordinate.
  ///
  /// The lat/long fields are editable, so the map restriction alone is not
  /// enough - a coordinate pasted straight into the box would otherwise sail
  /// past every check the map performs.
  String? _validateCoordinate(String? value, {required bool isLatitude}) {
    if (value == null || value.trim().isEmpty) return 'Required';

    final parsed = double.tryParse(value.trim());
    if (parsed == null) return 'Enter a valid number';

    final withinRange = isLatitude
        ? parsed >= CampusConfig.southLatitude &&
            parsed <= CampusConfig.northLatitude
        : parsed >= CampusConfig.westLongitude &&
            parsed <= CampusConfig.eastLongitude;

    return withinRange ? null : 'Outside ISU Cauayan Campus';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: Colors.grey.shade600,
                        ),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            "Only students enrolled in the class you pick "
                            "will see this session.",
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildClassPicker(),
                    const SizedBox(height: 32),

                    _buildScheduleSection(),
                    const SizedBox(height: 32),

                    const Text(
                      "Set Meeting Location",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: Colors.grey.shade600,
                        ),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            "Tap the map to set where students should check "
                            "in today. The map is limited to ISU Cauayan "
                            "Campus.",
                            style: TextStyle(fontSize: 13, color: Colors.grey),
                          ),
                        ),
                      ],
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
                                _pickedLocation ?? CampusConfig.center,
                            initialZoom: CampusConfig.initialZoom,
                            // Pen the camera inside the campus so the
                            // instructor cannot pan off to another town and
                            // drop the geofence where no student will be.
                            cameraConstraint: CameraConstraint.contain(
                              bounds: CampusConfig.bounds,
                            ),
                            minZoom: CampusConfig.minZoom,
                            maxZoom: CampusConfig.maxZoom,
                            onTap: _handleMapTap,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName:
                                  'ph.edu.isu.nstp.attendanceapp',
                            ),
                            // Draw the boundary so the limit is visible rather
                            // than just felt when the map refuses to pan.
                            PolygonLayer(
                              polygons: [
                                Polygon(
                                  points: [
                                    const LatLng(
                                      CampusConfig.southLatitude,
                                      CampusConfig.westLongitude,
                                    ),
                                    const LatLng(
                                      CampusConfig.southLatitude,
                                      CampusConfig.eastLongitude,
                                    ),
                                    const LatLng(
                                      CampusConfig.northLatitude,
                                      CampusConfig.eastLongitude,
                                    ),
                                    const LatLng(
                                      CampusConfig.northLatitude,
                                      CampusConfig.westLongitude,
                                    ),
                                  ],
                                  borderColor: Colors.blue.shade700,
                                  borderStrokeWidth: 2,
                                  color: Colors.blue.withValues(alpha: 0.05),
                                ),
                              ],
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
                            validator: (v) =>
                                _validateCoordinate(v, isLatitude: true),
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
                            validator: (v) =>
                                _validateCoordinate(v, isLatitude: false),
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

/// What the class is running, which decides whether random presence checks
/// are scheduled. Cleaning (default) keeps them; lecturing drops them and
/// does check-in + time-out only.
enum _SessionType {
  cleaning,
  lecturing,
}
