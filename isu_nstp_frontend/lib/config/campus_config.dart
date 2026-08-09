import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Geographic limits for Isabela State University - Cauayan Campus.
///
/// Attendance only ever happens on campus, so the meeting-location picker is
/// boxed in to it. Left unbounded the instructor can pan anywhere on Earth and
/// set a geofence in the wrong city - the students would then be unable to
/// check in from where they actually are, and nothing in the app would explain
/// why.
///
/// This governs where a session may be *placed*. It deliberately does not
/// apply to maps that display where a student actually stood: an off-campus
/// check-in is exactly the thing an instructor needs to see, not something to
/// hide behind a clamp.
class CampusConfig {
  CampusConfig._();

  /// Roughly the middle of the campus grounds. Used as the fallback whenever a
  /// stored or supplied coordinate turns out to be somewhere else.
  static const LatLng center = LatLng(16.937589, 121.763884);

  // The campus box, with a small margin so buildings at the edges are still
  // selectable. Kept a touch wider than the grounds themselves because the
  // check-in radius is measured outward from whatever point is chosen.
  static const double southLatitude = 16.9325;
  static const double northLatitude = 16.9425;
  static const double westLongitude = 121.7585;
  static const double eastLongitude = 121.7695;

  /// The bounds the map camera is not allowed to leave.
  static final LatLngBounds bounds = LatLngBounds(
    const LatLng(southLatitude, westLongitude),
    const LatLng(northLatitude, eastLongitude),
  );

  /// Zoom floor. The camera constraint can only hold if the visible area is
  /// smaller than the box - zooming further out than this would show more
  /// ground than the campus covers and the constraint would fight the user.
  static const double minZoom = 16.0;
  static const double maxZoom = 19.0;
  static const double initialZoom = 16.5;

  /// Whether a point sits inside the campus box.
  static bool contains(LatLng point) =>
      point.latitude >= southLatitude &&
      point.latitude <= northLatitude &&
      point.longitude >= westLongitude &&
      point.longitude <= eastLongitude;

  static bool containsCoordinates(double latitude, double longitude) =>
      contains(LatLng(latitude, longitude));

  /// The given point if it is on campus, otherwise the campus centre.
  ///
  /// Saved settings predate this restriction and may hold a coordinate from
  /// anywhere, so anything loaded from the server is passed through here
  /// rather than trusted.
  static LatLng clampToCampus(LatLng point) =>
      contains(point) ? point : center;

  /// Shown when someone tries to place a session off campus.
  static const String outsideMessage =
      'Please pick a location inside ISU Cauayan Campus.';
}
