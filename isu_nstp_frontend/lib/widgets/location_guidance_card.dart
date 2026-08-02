import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Turns a raw "you are 412m away" number into something a student can act on:
/// which way to walk, how far is left, and a map showing the target circle.
///
/// Deliberately dependency-free beyond what the app already uses (flutter_map +
/// latlong2), so no external directions/API key is required.
class LocationGuidanceCard extends StatelessWidget {
  final double targetLat;
  final double targetLng;
  final int allowedRadiusMeters;

  /// Null while the first GPS fix is still being acquired.
  final double? currentLat;
  final double? currentLng;

  /// Straight-line metres to the target. Negative means "not known yet".
  final double distanceMeters;

  const LocationGuidanceCard({
    super.key,
    required this.targetLat,
    required this.targetLng,
    required this.allowedRadiusMeters,
    required this.currentLat,
    required this.currentLng,
    required this.distanceMeters,
  });

  bool get _hasFix => currentLat != null && currentLng != null;
  bool get _isInside => distanceMeters >= 0 && distanceMeters <= allowedRadiusMeters;

  /// Metres still to cover before the check-in button unlocks.
  double get _metersToEdge =>
      math.max(0, distanceMeters - allowedRadiusMeters);

  /// Initial bearing from the student to the target, in degrees from north.
  double get _bearingDegrees {
    final lat1 = _toRadians(currentLat!);
    final lat2 = _toRadians(targetLat);
    final dLng = _toRadians(targetLng - currentLng!);

    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);

    final degrees = _toDegrees(math.atan2(y, x));
    return (degrees + 360) % 360;
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180.0;
  static double _toDegrees(double radians) => radians * 180.0 / math.pi;

  /// "north-east" style label, which reads better than a raw bearing.
  String get _compassLabel {
    const points = [
      'north', 'north-east', 'east', 'south-east',
      'south', 'south-west', 'west', 'north-west',
    ];
    // Each of the 8 sectors covers 45 degrees, offset by half a sector so that
    // 350 degrees still reads as "north" rather than "north-west".
    final index = (((_bearingDegrees + 22.5) % 360) / 45).floor();
    return points[index % 8];
  }

  /// Rough walking time at a relaxed 1.35 m/s.
  String get _walkEstimate {
    final minutes = (_metersToEdge / 1.35 / 60).ceil();
    if (minutes <= 1) return 'about a minute on foot';
    return 'about $minutes minutes on foot';
  }

  String get _readableDistance {
    if (distanceMeters < 0) return '--';
    if (distanceMeters >= 1000) {
      return '${(distanceMeters / 1000).toStringAsFixed(2)} km';
    }
    return '${distanceMeters.toStringAsFixed(0)} m';
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasFix) {
      return _shell(
        color: Colors.blueGrey.shade50,
        border: Colors.blueGrey.shade200,
        child: const Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Finding your location so we can guide you to the activity site...',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    if (_isInside) {
      return _shell(
        color: Colors.green.shade50,
        border: Colors.green.shade200,
        child: Row(
          children: [
            Icon(Icons.where_to_vote, color: Colors.green.shade700),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "You have arrived. You are $_readableDistance from the centre, "
                'inside the ${allowedRadiusMeters}m check-in zone.',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    return _shell(
      color: Colors.orange.shade50,
      border: Colors.orange.shade300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // The arrow physically points at the target: 0 degrees on the
              // icon already points up/north, so the bearing maps directly.
              Transform.rotate(
                angle: _toRadians(_bearingDegrees),
                child: Icon(
                  Icons.navigation,
                  size: 30,
                  color: Colors.orange.shade800,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Head $_compassLabel for ${_metersToEdge.toStringAsFixed(0)} m',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Colors.orange.shade900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'You are $_readableDistance from the activity site, '
                      '$_walkEstimate.',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildMiniMap(),
          const SizedBox(height: 6),
          Text(
            'The arrow points straight at the site. Follow safe roads and paths '
            'rather than the straight line.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }

  Widget _shell({
    required Color color,
    required Color border,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: child,
    );
  }

  /// Small map with the student, the target circle, and the line between them.
  Widget _buildMiniMap() {
    final me = LatLng(currentLat!, currentLng!);
    final target = LatLng(targetLat, targetLng);

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: 170,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: LatLng(
              (me.latitude + target.latitude) / 2,
              (me.longitude + target.longitude) / 2,
            ),
            initialZoom: _zoomForDistance(distanceMeters),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'ph.edu.isu.nstp.attendanceapp',
            ),
            CircleLayer(
              circles: [
                CircleMarker(
                  point: target,
                  radius: allowedRadiusMeters.toDouble(),
                  useRadiusInMeter: true,
                  color: Colors.green.withValues(alpha: 0.20),
                  borderColor: Colors.green.shade700,
                  borderStrokeWidth: 2,
                ),
              ],
            ),
            PolylineLayer(
              polylines: [
                Polyline(
                  points: [me, target],
                  strokeWidth: 3,
                  color: Colors.orange.shade800,
                ),
              ],
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: target,
                  width: 40,
                  height: 40,
                  child: Icon(Icons.flag, color: Colors.green.shade800, size: 30),
                ),
                Marker(
                  point: me,
                  width: 40,
                  height: 40,
                  child: const Icon(Icons.person_pin_circle,
                      color: Colors.blue, size: 30),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Zoom out as the student gets further away so both pins stay on screen.
  double _zoomForDistance(double meters) {
    if (meters < 200) return 17;
    if (meters < 600) return 15.5;
    if (meters < 2000) return 14;
    if (meters < 8000) return 12;
    return 10.5;
  }
}
