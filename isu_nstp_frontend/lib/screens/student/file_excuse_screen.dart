import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../config/api_config.dart';
import '../../models/user_model.dart';
import '../../widgets/excuse_dialog.dart';

/// Lets a student file an excuse letter in advance for an upcoming session
/// they know they cannot attend, with an optional file attachment.
///
/// Lists the student's upcoming sessions (from their enrolled classes) that
/// do not already have an excuse filed. Tapping one opens the excuse dialog,
/// and filing removes it from the list.
class FileExcuseScreen extends StatefulWidget {
  final UserModel user;
  const FileExcuseScreen({super.key, required this.user});

  @override
  State<FileExcuseScreen> createState() => _FileExcuseScreenState();
}

class _FileExcuseScreenState extends State<FileExcuseScreen> {
  static const Color isuGreen = Color(0xFF006837);

  bool _isLoading = true;
  String? _error;
  List<Map<String, dynamic>> _sessions = [];

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await http.get(
        Uri.parse(ApiConfig.upcomingSessionsUrl(widget.user.id)),
        headers: {'ngrok-skip-browser-warning': 'true'},
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final sessions = body['sessions'];
        setState(() {
          _sessions = sessions is List
              ? sessions.cast<Map<String, dynamic>>()
              : [];
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Could not load upcoming sessions (${response.statusCode}).';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Network error: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _fileExcuse(Map<String, dynamic> session) async {
    // Convert the upcoming-session row into the shape the excuse dialog expects.
    final record = {
      'session_id': session['session_id'],
      'title': session['title'],
      'class_name': session['class_name'],
      'date_time': '${session['date_time']} ${session['start_time']}',
    };

    final submitted = await showSubmitExcuseDialog(
      context: context,
      user: widget.user,
      record: record,
    );

    if (submitted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Excuse submitted. Your instructor has been notified.'),
          backgroundColor: Colors.green,
        ),
      );
      await _loadSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('File an Excuse'),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
      ),
      body: RefreshIndicator(
        onRefresh: _loadSessions,
        color: isuGreen,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 40),
          Center(
            child: Column(
              children: [
                const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _loadSessions,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (_sessions.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 40),
          Center(
            child: Column(
              children: [
                Icon(Icons.event_available, size: 64, color: Colors.grey.shade600),
                const SizedBox(height: 16),
                const Text(
                  'No upcoming sessions',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'There are no upcoming NSTP activities for your class that '
                  'need an excuse right now. Pull down to refresh.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.blue.shade200),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 20, color: Colors.grey.shade600),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Pick an upcoming session you cannot attend, then explain why. '
                  'You can attach a medical certificate or a picture as proof. '
                  'Your instructor will review it.',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.blue.shade900,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ..._sessions.map(
          (session) => Card(
            elevation: 1,
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: CircleAvatar(
                backgroundColor: Colors.blue.withValues(alpha: 0.12),
                child: Icon(Icons.event, color: Colors.grey.shade600),
              ),
              title: Text(
                session['title']?.toString() ?? 'NSTP Activity',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (session['class_name']?.toString().isNotEmpty ?? false)
                    Text(
                      session['class_name'].toString(),
                      style: const TextStyle(fontSize: 12),
                    ),
                  Text(
                    '${session['date_time']} at ${session['start_time']}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              trailing: FilledButton(
                onPressed: () => _fileExcuse(session),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
                child: const Text('File'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
