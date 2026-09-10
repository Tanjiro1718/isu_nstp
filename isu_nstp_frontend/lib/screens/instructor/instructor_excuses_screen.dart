import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../config/api_config.dart';
import '../../models/user_model.dart';

/// The instructor's excuse queue: letters students filed about sessions this
/// instructor owns.
///
/// Approving one marks that student "Excused" for the session, which is why
/// the reason is shown in full rather than truncated - the whole point is to
/// let the instructor read it before deciding.
class InstructorExcusesScreen extends StatefulWidget {
  final UserModel user;

  /// True when hosted as a dashboard tab: drops the title and back arrow but
  /// keeps the bar so Refresh stays reachable.
  final bool embedded;

  const InstructorExcusesScreen({
    super.key,
    required this.user,
    this.embedded = false,
  });

  @override
  State<InstructorExcusesScreen> createState() => _InstructorExcusesScreenState();
}

class _InstructorExcusesScreenState extends State<InstructorExcusesScreen> {
  static const Color isuGreen = Color(0xFF006837);
  static const Color isuDarkGreen = Color(0xFF004D25);

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _excuses = const [];
  String _statusFilter = 'pending';

  /// Ids currently being approved/rejected, so only the affected card shows a
  /// spinner instead of freezing the entire queue.
  final Set<int> _working = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http
          .get(
            Uri.parse(ApiConfig.excuseReviewQueueUrl(
              widget.user.id,
              status: _statusFilter,
            )),
            headers: const {'ngrok-skip-browser-warning': 'true'},
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (response.statusCode != 200) {
        setState(() {
          _loading = false;
          _error = 'Could not load excuses (${response.statusCode}).';
        });
        return;
      }

      final decoded = json.decode(response.body);
      final List rows = decoded is List
          ? decoded
          : (decoded is Map
              ? ((decoded['excuses'] ?? decoded['results']) as List? ?? const [])
              : const []);

      setState(() {
        _loading = false;
        _excuses =
            rows.map((e) => (e as Map).cast<String, dynamic>()).toList();
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Connection timed out. Please try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not reach the server. Check your connection.';
      });
    }
  }

  /// Confirms, then sends the ruling.
  ///
  /// Approving rewrites a student's attendance record, so it is never a
  /// single stray tap - the dialog also collects the optional note the student
  /// will see alongside the outcome.
  Future<void> _review(Map<String, dynamic> excuse, bool approve) async {
    final id = excuse['id'];
    final excuseId = id is int ? id : int.tryParse('$id');
    if (excuseId == null) return;

    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(approve ? 'Approve excuse?' : 'Reject excuse?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              approve
                  ? '${excuse['student_name'] ?? 'This student'} will be marked '
                      'Excused for this activity.'
                  : 'The absence stands. The student will see your reply.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              maxLines: 3,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Note to student (optional)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: approve ? isuGreen : Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            child: Text(approve ? 'Approve' : 'Reject'),
          ),
        ],
      ),
    );

    final note = noteController.text.trim();
    noteController.dispose();

    if (confirmed != true || !mounted) return;

    setState(() => _working.add(excuseId));

    try {
      final response = await http
          .patch(
            Uri.parse(ApiConfig.reviewExcuseUrl(excuseId)),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'instructor_id': widget.user.id,
              'decision': approve ? 'approve' : 'reject',
              if (note.isNotEmpty) 'response_note': note,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;

      setState(() => _working.remove(excuseId));

      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(approve ? 'Excuse approved.' : 'Excuse rejected.'),
            backgroundColor: approve ? isuGreen : Colors.red.shade700,
          ),
        );
        await _load();
        return;
      }

      String message = 'Could not save your decision.';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] != null) {
          message = decoded['error'].toString();
        }
      } catch (_) {
        // Keep the generic message.
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _working.remove(excuseId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Network error. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: widget.embedded ? null : const Text('Excuse Letters'),
        toolbarHeight: widget.embedded ? 48 : null,
        automaticallyImplyLeading: !widget.embedded,
        backgroundColor: isuGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildFilterChips(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              color: isuGreen,
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips() {
    Widget chip(String label, String value) {
      final selected = _statusFilter == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) {
            if (_statusFilter == value) return;
            setState(() => _statusFilter = value);
            _load();
          },
          selectedColor: isuGreen,
          labelStyle: TextStyle(
            color: selected ? Colors.white : Colors.black87,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            chip('Pending', 'pending'),
            chip('Approved', 'approved'),
            chip('Rejected', 'rejected'),
            chip('All', 'all'),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: isuGreen));
    }

    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 60),
          Icon(Icons.cloud_off, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 20),
          Center(
            child: FilledButton.icon(
              onPressed: _load,
              style: FilledButton.styleFrom(backgroundColor: isuGreen),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
            ),
          ),
        ],
      );
    }

    if (_excuses.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 60),
          Icon(Icons.inbox_outlined, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            _statusFilter == 'pending'
                ? 'No excuses waiting for review.'
                : 'Nothing in this category.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: isuDarkGreen,
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _excuses.length,
      itemBuilder: (_, index) => _buildExcuseCard(_excuses[index]),
    );
  }

  Widget _buildExcuseCard(Map<String, dynamic> excuse) {
    final status = (excuse['status']?.toString() ?? 'pending').toLowerCase();
    final isPending = status == 'pending';
    final id = excuse['id'];
    final excuseId = id is int ? id : int.tryParse('$id');
    final busy = excuseId != null && _working.contains(excuseId);

    final MaterialColor color;
    switch (status) {
      case 'approved':
        color = Colors.green;
        break;
      case 'rejected':
        color = Colors.red;
        break;
      default:
        color = Colors.blue;
    }

    final responseNote = excuse['response_note']?.toString();

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        excuse['student_name']?.toString() ?? 'Student',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: isuDarkGreen,
                        ),
                      ),
                      if (excuse['student_number'] != null)
                        Text(
                          excuse['student_number'].toString(),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.black54),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.shade50,
                    border: Border.all(color: color.shade300),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    status[0].toUpperCase() + status.substring(1),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: color.shade900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              excuse['session_title']?.toString() ?? 'Activity',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            Text(
              [
                excuse['class_name']?.toString() ?? '',
                excuse['session_date']?.toString() ?? '',
              ].where((s) => s.isNotEmpty).join('  •  '),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                excuse['reason']?.toString() ?? '',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            if (excuse['attachment_url'] != null &&
                excuse['attachment_url'].toString().isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildAttachmentSection(excuse['attachment_url'].toString()),
            ],
            if (excuse['submitted_at'] != null) ...[
              const SizedBox(height: 6),
              Text(
                'Submitted ${excuse['submitted_at']}',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ],
            if (!isPending && responseNote != null && responseNote.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Your note: $responseNote',
                style: const TextStyle(fontSize: 11, color: Colors.black87),
              ),
            ],
            if (isPending) ...[
              const Divider(height: 22),
              if (busy)
                const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: isuGreen,
                    ),
                  ),
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => _review(excuse, false),
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('Reject'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => _review(excuse, true),
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Approve'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isuGreen,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }

  bool _isImageUrl(String url) {
    final lower = url.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp');
  }

  String _fileNameFromUrl(String url) {
    final segments = Uri.parse(url).pathSegments;
    if (segments.isEmpty) return 'attachment';
    return segments.last;
  }

  Widget _buildAttachmentSection(String url) {
    if (_isImageUrl(url)) {
      return GestureDetector(
        onTap: () => _viewFullImage(url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 150),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.broken_image, color: Colors.grey.shade500),
                    const SizedBox(width: 8),
                    Text(
                      'Could not load image',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // PDF / doc — show a tappable chip
    final fileName = _fileNameFromUrl(url);
    return InkWell(
      onTap: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blue.shade200),
        ),
        child: Row(
          children: [
            Icon(
              fileName.toLowerCase().endsWith('.pdf')
                  ? Icons.picture_as_pdf
                  : Icons.description,
              size: 20,
              color: Colors.grey.shade600,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fileName,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade700,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.open_in_new, size: 16, color: Colors.grey.shade600),
          ],
        ),
      ),
    );
  }

  void _viewFullImage(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Stack(
            alignment: Alignment.center,
            children: [
              InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image, color: Colors.white54, size: 48),
                        SizedBox(height: 8),
                        Text('Could not load image',
                            style: TextStyle(color: Colors.white54)),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 16,
                right: 16,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
