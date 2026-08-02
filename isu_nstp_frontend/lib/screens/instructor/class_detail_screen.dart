import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/class_model.dart';
import '../../services/class_service.dart';

/// Shows the full roster + invite-sharing actions for one class.
class ClassDetailScreen extends StatefulWidget {
  final int classId;
  const ClassDetailScreen({super.key, required this.classId});

  @override
  State<ClassDetailScreen> createState() => _ClassDetailScreenState();
}

class _ClassDetailScreenState extends State<ClassDetailScreen> {
  late Future<ClassModel> _classFuture;

  @override
  void initState() {
    super.initState();
    _loadClass();
  }

  void _loadClass() {
    _classFuture = ClassService.fetchClassDetail(widget.classId);
  }

  Future<void> _refresh() async {
    setState(_loadClass);
    // Swallow the error here; the FutureBuilder renders the failure state.
    try {
      await _classFuture;
    } catch (_) {}
  }


  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade600 : Colors.green.shade600,
      ),
    );
  }

  Future<void> _copyJoinCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    _showSnack('Join code copied: ${code.toUpperCase()}');
  }

  Future<void> _shareInviteLink(String link, String className) async {
    await Share.share(
      'Join my class "$className" on ISU NSTP App:\n\n$link',
      subject: 'Join $className',
    );
  }

  Future<void> _rotateCode() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rotate join code?'),
        content: const Text(
          'This generates a new code and invalidates the previous one. '
          'Students with the old code will not be able to join anymore.',
        ),

        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rotate'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final newCode = await ClassService.rotateJoinCode(widget.classId);
      _showSnack('New code: ${newCode.toUpperCase()}');
      setState(_loadClass);
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _toggleJoinEnabled(bool current) async {
    try {
      await ClassService.updateClass(
        widget.classId,
        {'is_join_enabled': !current},
      );
      _showSnack(current ? 'Class is now closed' : 'Class is now open');
      setState(_loadClass);
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _approveMember(int enrollmentId) async {
    try {
      await ClassService.updateEnrollmentStatus(enrollmentId, 'active');
      _showSnack('Student approved');
      setState(_loadClass);
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  Future<void> _removeMember(int enrollmentId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove student?'),
        content: Text('$name will no longer see this class.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ClassService.removeStudent(enrollmentId);
      _showSnack('$name removed from class');
      setState(_loadClass);
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text('Class Details'),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<ClassModel>(
          future: _classFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return _ErrorState(
                message: snapshot.error.toString(),
                onRetry: () => setState(_loadClass),
              );
            }

            final classGroup = snapshot.data!;
            final members = classGroup.members ?? [];
            final activeMembers =
                members.where((m) => m.status == 'active').toList();
            final pendingMembers =
                members.where((m) => m.status == 'pending').toList();

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _HeaderCard(
                  classGroup: classGroup,
                  onCopyCode: () => _copyJoinCode(classGroup.joinCode),
                  onShareLink: () => _shareInviteLink(
                    classGroup.inviteLink,
                    classGroup.name,
                  ),
                  onRotateCode: _rotateCode,
                  onToggleJoin: () =>
                      _toggleJoinEnabled(classGroup.isJoinEnabled),
                ),
                const SizedBox(height: 20),
                if (pendingMembers.isNotEmpty) ...[
                  _SectionHeader(
                    icon: Icons.hourglass_top,
                    label: 'Pending (${pendingMembers.length})',
                    color: Colors.orange,
                  ),
                  const SizedBox(height: 8),
                  ...pendingMembers.map(
                    (member) => _MemberCard(
                      member: member,
                      onApprove: () => _approveMember(member.enrollmentId),
                      onRemove: () => _removeMember(
                        member.enrollmentId,
                        member.studentName,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                _SectionHeader(
                  icon: Icons.people,
                  label: 'Members (${activeMembers.length})',
                  color: Colors.green,
                ),
                const SizedBox(height: 8),
                if (activeMembers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No active members yet',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                else
                  ...activeMembers.map(
                    (member) => _MemberCard(
                      member: member,
                      onRemove: () => _removeMember(
                        member.enrollmentId,
                        member.studentName,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final ClassModel classGroup;
  final VoidCallback onCopyCode;
  final VoidCallback onShareLink;
  final VoidCallback onRotateCode;
  final VoidCallback onToggleJoin;

  const _HeaderCard({
    required this.classGroup,
    required this.onCopyCode,
    required this.onShareLink,
    required this.onRotateCode,
    required this.onToggleJoin,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              classGroup.name,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              [
                classGroup.component,
                if (classGroup.sectionCode.isNotEmpty) classGroup.sectionCode,
              ].join(' • '),
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
            ),
            if (classGroup.description != null &&
                classGroup.description!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                classGroup.description!,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F3F9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Join Code',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        classGroup.joinCode.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 3,
                          color: Colors.blueAccent,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: 'Copy code',
                        onPressed: onCopyCode,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Rotate code',
                        onPressed: onRotateCode,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onShareLink,
                    icon: const Icon(Icons.share),
                    label: const Text('Share invite link'),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: onToggleJoin,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: classGroup.isJoinEnabled
                        ? Colors.red
                        : Colors.green,
                  ),
                  child: Text(classGroup.isJoinEnabled ? 'Close' : 'Open'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _SectionHeader({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _MemberCard extends StatelessWidget {
  final ClassMember member;
  final VoidCallback? onApprove;
  final VoidCallback onRemove;

  const _MemberCard({
    required this.member,
    this.onApprove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isPending = member.status == 'pending';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: isPending
                  ? Colors.orange.withValues(alpha: 0.15)
                  : Colors.green.withValues(alpha: 0.15),
              child: Text(
                member.studentName.isNotEmpty
                    ? member.studentName[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  color: isPending ? Colors.orange : Colors.green,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    member.studentName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    member.studentId,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  if (member.courseAndSection.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      member.courseAndSection,
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                  ],
                ],
              ),
            ),
            if (onApprove != null)
              IconButton(
                icon: const Icon(Icons.check_circle_outline, color: Colors.green),
                tooltip: 'Approve',
                onPressed: onApprove,
              ),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
              tooltip: 'Remove',
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.cloud_off, size: 64, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade700),
        ),
        const SizedBox(height: 20),
        Center(
          child: FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ),
      ],
    );
  }
}
