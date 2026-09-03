import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Full-screen front-camera capture for a presence check.
///
/// The student must snap a live selfie to prove they are physically present.
/// Returns the captured image `File` when the student taps "Use this
/// photo", or `null` if they back out / retake / the camera fails.
class PresenceCheckPhotoScreen extends StatefulWidget {
  const PresenceCheckPhotoScreen({super.key});

  @override
  State<PresenceCheckPhotoScreen> createState() =>
      _PresenceCheckPhotoScreenState();
}

class _PresenceCheckPhotoScreenState extends State<PresenceCheckPhotoScreen> {
  CameraController? _controller;
  XFile? _captured;
  bool _isInitializing = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(front, ResolutionPreset.high);
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _isInitializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _error = 'Could not start the camera: $e';
      });
    }
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final shot = await controller.takePicture();
      if (!mounted) return;
      setState(() => _captured = shot);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not take photo: $e')),
      );
    }
  }

  Future<void> _retake() async {
    setState(() => _captured = null);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_captured == null ? 'Confirm Presence' : 'Review Photo'),
        backgroundColor: Colors.orange.shade800,
        foregroundColor: Colors.white,
      ),
      body: _isInitializing
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam_off, size: 48,
                            color: Colors.grey),
                        const SizedBox(height: 12),
                        Text(_error, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () {
                            setState(() {
                              _error = '';
                              _isInitializing = true;
                            });
                            _initCamera();
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : _captured != null
                  ? _buildReview()
                  : _buildCapture(),
    );
  }

  Widget _buildCapture() {
    return Column(
      children: [
        Expanded(
          child: ClipRect(
            child: _controller != null && _controller!.value.isInitialized
                ? CameraPreview(_controller!)
                : Container(
                    color: Colors.black,
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Take a selfie to prove you are here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _takePicture,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.orange.shade800,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Snap photo'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReview() {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(File(_captured!.path)),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _retake,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retake'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, _captured),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.orange.shade800,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Use this photo'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
