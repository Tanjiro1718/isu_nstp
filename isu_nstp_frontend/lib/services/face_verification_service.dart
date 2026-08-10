import 'dart:io';
import 'dart:typed_data';

import 'package:face_detection_tflite/face_detection_tflite.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';

/// Outcome of an on-device face check.
enum FaceVerifyStatus {
  /// The live selfie's face matched the student's reference photo.
  verified,

  /// A face was found but it did not match the reference closely enough.
  mismatch,

  /// No face could be detected in the selfie.
  noFace,

  /// No reference photo is on file (or it could not be used), so verification
  /// is impossible. Check-in still proceeds, just unverified.
  unavailable,

  /// Something unexpected failed (model load, download, decode).
  error,
}

class FaceVerifyResult {
  final FaceVerifyStatus status;
  final double similarity;

  /// Friendly text the check-in screen shows under the camera.
  final String message;

  const FaceVerifyResult({
    required this.status,
    this.similarity = 0.0,
    required this.message,
  });

  /// Whether the server should record the check-in as face-verified.
  bool get isVerified => status == FaceVerifyStatus.verified;
}

/// Runs MediaPipe face recognition entirely on-device.
///
/// The reference is the student's uploaded ID photo ([UserModel.idPictureUrl]).
/// It is embedded once and cached locally so the next time-in is fast. The
/// live selfie is embedded at time-in and compared with cosine similarity.
///
/// Nothing about the face leaves the device except the boolean/similarity
/// result the app sends to the server, so a spoofed result is the main threat
/// to keep in mind (the flag is client-reported).
class FaceVerificationService {
  FaceVerificationService._();

  static final FaceVerificationService instance = FaceVerificationService._();

  /// Cosine similarity above this is treated as "the same person".
  ///
  /// MediaPipe's guidance: >0.6 very likely same, >0.5 probably same,
  /// <0.3 different people. Kept conservative because school ID photos and
  /// live selfies differ in lighting, age, and angle.
  static const double matchThreshold = 0.5;

  /// Included in the reference cache key so old embeddings are ignored after
  /// a package upgrade that changes the model outputs.
  static const String _modelVersion = FaceDetector.modelVersion;

  FaceDetector? _detector;
  Future<FaceDetector>? _detectorFuture;

  /// Lazily creates and initializes the detector (loads ~25MB of models in a
  /// background isolate). Reused for the life of the app session.
  Future<FaceDetector> _getDetector() {
    return _detectorFuture ??= () async {
      final detector = await FaceDetector.create(
        // Front-camera BlazeFace: selfies and ID photos are close-range.
        model: FaceDetectionModel.frontCamera,
      );
      _detector = detector;
      return detector;
    }();
  }

  /// Verifies [selfie] against the student's reference photo.
  ///
  /// Never throws for a normal face check; on any failure it returns
  /// [FaceVerifyStatus.error] so the check-in can still proceed.
  Future<FaceVerifyResult> verifySelfie({
    required File selfie,
    required int studentUserId,
    required String? referenceUrl,
  }) async {
    final resolvedReference = _resolveUrl(referenceUrl);
    if (resolvedReference == null || resolvedReference.isEmpty) {
      return const FaceVerifyResult(
        status: FaceVerifyStatus.unavailable,
        message: 'No face reference on file. '
            'Check-in recorded without face verification.',
      );
    }

    try {
      final detector = await _getDetector();

      final referenceEmbedding = await _referenceEmbedding(
        detector,
        studentUserId: studentUserId,
        referenceUrl: resolvedReference,
      );
      if (referenceEmbedding == null) {
        return const FaceVerifyResult(
          status: FaceVerifyStatus.unavailable,
          message: 'Could not read a face from your ID photo. '
              'Check-in recorded without face verification.',
        );
      }

      final selfieBytes = await selfie.readAsBytes();
      final selfieEmbedding = await _embedFromBytes(detector, selfieBytes);
      if (selfieEmbedding == null) {
        return const FaceVerifyResult(
          status: FaceVerifyStatus.noFace,
          message: 'No face recognized in the photo. '
              'Your time-in was recorded but flagged for review.',
        );
      }

      final similarity = FaceDetector.compareFaces(
        referenceEmbedding,
        selfieEmbedding,
      );

      if (similarity >= matchThreshold) {
        return FaceVerifyResult(
          status: FaceVerifyStatus.verified,
          similarity: similarity,
          message: 'Face verified (${_pct(similarity)} match).',
        );
      }

      return FaceVerifyResult(
        status: FaceVerifyStatus.mismatch,
        similarity: similarity,
        message: 'Face did not match your record '
            '(${_pct(similarity)}). Check-in recorded for review.',
      );
    } catch (e) {
      return FaceVerifyResult(
        status: FaceVerifyStatus.error,
        message: 'Face check failed ($e). '
            'Check-in recorded without face verification.',
      );
    }
  }

  /// Downloads the reference photo, embeds it once, and caches the vector so
  /// subsequent check-ins skip the download and second embed. Returns null if
  /// no usable face is found.
  Future<Float32List?> _referenceEmbedding(
    FaceDetector detector, {
    required int studentUserId,
    required String referenceUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = 'face_ref_embedding_${_modelVersion}_$studentUserId';
    final cached = prefs.getString(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      return _decodeEmbedding(cached);
    }

    final response = await http.get(
      Uri.parse(referenceUrl),
      headers: const {'ngrok-skip-browser-warning': 'true'},
    );
    if (response.statusCode != 200) return null;

    final embedding = await _embedFromBytes(detector, response.bodyBytes);
    if (embedding == null) return null;

    await prefs.setString(cacheKey, _encodeEmbedding(embedding));
    return embedding;
  }

  /// Detects a face and returns its 192-dim embedding, or null when no face
  /// (with usable eye landmarks) is present.
  Future<Float32List?> _embedFromBytes(
    FaceDetector detector,
    Uint8List bytes,
  ) async {
    final faces = await detector.detectFacesFromBytes(
      bytes,
      mode: FaceDetectionMode.fast,
    );
    if (faces.isEmpty) return null;
    // Prefer the largest face so a bystander in frame does not trigger a
    // spurious match.
    Face best = faces.first;
    for (final face in faces.skip(1)) {
      final bb = face.detectionData.boundingBox;
      final bestBb = best.detectionData.boundingBox;
      final area = (bb.xmax - bb.xmin) * (bb.ymax - bb.ymin);
      final bestArea = (bestBb.xmax - bestBb.xmin) * (bestBb.ymax - bestBb.ymin);
      if (area > bestArea) best = face;
    }
    try {
      return await detector.getFaceEmbedding(best, bytes);
    } catch (_) {
      // Eye landmarks missing (e.g. heavily rotated face).
      return null;
    }
  }

  String? _resolveUrl(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    final trimmed = url.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    // Serializer falls back to a relative path when no request context exists.
    return '${ApiConfig.baseUrl}$trimmed';
  }

  String _encodeEmbedding(Float32List embedding) =>
      embedding.map((v) => v.toStringAsFixed(6)).join(',');

  Float32List? _decodeEmbedding(String encoded) {
    try {
      return Float32List.fromList(
        encoded.split(',').map(double.parse).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  String _pct(double similarity) {
    final percent = ((similarity + 1) / 2 * 100).clamp(0, 100);
    return '${percent.toStringAsFixed(0)}%';
  }

  /// Releases the model isolate. Call when the check-in screen closes.
  Future<void> dispose() async {
    final detector = _detector;
    _detector = null;
    _detectorFuture = null;
    if (detector != null && detector.isReady) {
      await detector.dispose();
    }
  }
}
