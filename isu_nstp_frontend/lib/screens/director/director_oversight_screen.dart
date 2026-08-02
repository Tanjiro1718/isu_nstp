import 'package:flutter/material.dart';

import '../../services/director_service.dart';

/// Campus oversight for the NSTP director.
///
/// Two views over the same data: "By Class" shows every class with the
/// instructor assigned to it, "By Instructor" rolls those classes up per
/// instructor. Tapping a class opens its session-by-session breakdown.
class DirectorOversightScreen extends StatefulWidget {
  /// 0 = By Class, 1 = By Instructor.
  final int initialTab;

  const DirectorOversightScreen({super.key, this.initialTab = 0});

  @override
  State<DirectorOversightScreen> createState() =>
      _DirectorOversightScreenState();
}

class _DirectorOversightScreenState extends State<DirectorOversightScreen>
    with SingleTickerProviderStateMixin {
  static const Color _accent = Color(0xFFE64A19); // deepOrange 700

  late final TabController _tabController;

  DirectorOverview? _overview;
  bool _isLoading = true;
  String? _error;

  /// null = every component.
  String? _component;
  static const _components = ['CWTS', 'LTS', 'ROTC'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1),
    );
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final overview = await DirectorService.fetchOverview(
        component: _component,
      );
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Exception.toString() prefixes "Exception: "; strip it for the user.
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------
  // Health presentation
  // ---------------------------------------------------------------

  static Color _healthColor(Health health) {
    switch (health) {
      case Health.good:
        return Colors.green;
      case Health.fair:
        return Colors.amber.shade800;
      case Health.attention:
        return Colors.red;
      case Health.noData:
        return Colors.grey;
    }
  }

  static String _healthLabel(Health health) {
    switch (health) {
      case Health.good:
        return 'Looks good';
      case Health.fair:
        return 'Fair';
      case Health.attention:
        return 'Needs attention';
      case Health.noData:
        return 'No data yet';
    }
  }

  static IconData _healthIcon(Health health) {
    switch (health) {
      case Health.good:
        return Icons.check_circle;
      case Health.fair:
        return Icons.error_outline;
      case Health.attention:
        return Icons.warning_amber_rounded;
      case Health.noData:
        return Icons.remove_circle_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Oversight'),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _isLoading ? null : _load,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(text: 'By Class', icon: Icon(Icons.class_)),
            Tab(text: 'By Instructor', icon: Icon(Icons.person)),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final overview = _overview!;
    return TabBarView(
      controller: _tabController,
      children: [
        _buildClassTab(overview),
        _buildInstructorTab(overview),
      ],
    );
  }

  // ---------------------------------------------------------------
  // Tab 1: by class
  // ---------------------------------------------------------------

  Widget _buildClassTab(DirectorOverview overview) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSummaryCard(overview.summary),
          const SizedBox(height: 12),
          _buildComponentFilter(),
          const SizedBox(height: 12),
          if (overview.classes.isEmpty)
            _buildEmpty('No classes found for this filter.')
          else
            ...overview.classes.map(_buildClassCard),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(CampusSummary summary) {
    final color = _healthColor(summary.health);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_healthIcon(summary.health), color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Campus attendance: ${summary.attendanceRate}%',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _healthLabel(summary.health),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip('Classes', '${summary.totalClasses}', Colors.blue),
                _chip('Instructors', '${summary.totalInstructors}', Colors.indigo),
                _chip('Students', '${summary.totalStudents}', Colors.teal),
                _chip('Sessions', '${summary.totalSessions}', Colors.purple),
              ],
            ),
            if (summary.classesNeedingAttention > 0 ||
                summary.classesWithoutSessions > 0 ||
                summary.failedVerifications > 0) ...[
              const Divider(height: 24),
              if (summary.classesNeedingAttention > 0)
                _alertLine(
                  Icons.warning_amber_rounded,
                  Colors.red,
                  '${summary.classesNeedingAttention} class(es) below '
                  '70% attendance',
                ),
              if (summary.classesWithoutSessions > 0)
                _alertLine(
                  Icons.event_busy,
                  Colors.orange,
                  '${summary.classesWithoutSessions} class(es) have not held '
                  'a session yet',
                ),
              if (summary.failedVerifications > 0)
                _alertLine(
                  Icons.gpp_bad,
                  Colors.deepOrange,
                  '${summary.failedVerifications} failed presence '
                  'verification(s) campus-wide',
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _alertLine(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String value, MaterialColor color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.shade50,
        border: Border.all(color: color.shade200),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color.shade900,
        ),
      ),
    );
  }

  Widget _buildComponentFilter() {
    return Row(
      children: [
        const Text('Component:', style: TextStyle(fontSize: 13)),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 8,
            children: [
              _filterChip('All', null),
              ..._components.map((c) => _filterChip(c, c)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filterChip(String label, String? value) {
    final selected = _component == value;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) {
        if (_component == value) return;
        setState(() => _component = value);
        _load();
      },
    );
  }

  Widget _buildClassCard(ClassOversight c) {
    final color = _healthColor(c.health);

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showClassSessions(c),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_healthIcon(c.health), color: color, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.className,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  Text(
                    c.health == Health.noData ? '--' : '${c.attendanceRate}%',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: color,
                    ),
                  ),
                ],
              ),
              if (c.subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  c.subtitle,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
              const SizedBox(height: 8),

              // The assignment the director came here to see.
              Row(
                children: [
                  const Icon(Icons.person, size: 15, color: Colors.blueGrey),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Instructor: ${c.instructorName}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              if (c.health != Health.noData)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (c.attendanceRate / 100).clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              const SizedBox(height: 10),

              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _miniStat(Icons.group, '${c.studentCount} students'),
                  _miniStat(Icons.event, '${c.sessionCount} sessions'),
                  _miniStat(Icons.login, '${c.checkInCount} check-ins'),
                  if (c.failedCount > 0)
                    _miniStat(
                      Icons.gpp_bad,
                      '${c.failedCount} failed',
                      color: Colors.red,
                    ),
                ],
              ),

              if (c.lastSession != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Last session: ${c.lastSession}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],

              // Call out the two states that need the director to act.
              if (c.noSessionsYet || c.noStudentsYet) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    border: Border.all(color: Colors.orange.shade200),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    c.noStudentsYet
                        ? 'No students have joined this class yet.'
                        : 'This class has not held an attendance session yet.',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange.shade900,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniStat(IconData icon, String text, {Color color = Colors.grey}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }

  // ---------------------------------------------------------------
  // Tab 2: by instructor
  // ---------------------------------------------------------------

  Widget _buildInstructorTab(DirectorOverview overview) {
    if (overview.instructors.isEmpty) {
      return _buildEmpty('No instructors have classes yet.');
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: overview.instructors.map((i) {
          final flagged = i.classesNeedingAttention > 0;

          return Card(
            elevation: 2,
            margin: const EdgeInsets.only(bottom: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: flagged
                            ? Colors.red.withValues(alpha: 0.15)
                            : Colors.blueGrey.withValues(alpha: 0.15),
                        child: Icon(
                          Icons.person,
                          size: 20,
                          color: flagged ? Colors.red : Colors.blueGrey,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              i.instructorName,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            if (i.instructorEmail.isNotEmpty)
                              Text(
                                i.instructorEmail,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _miniStat(Icons.class_, '${i.classCount} classes'),
                      _miniStat(Icons.group, '${i.studentCount} students'),
                      _miniStat(Icons.event, '${i.sessionCount} sessions'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Assigned to: ${i.classNames.join(', ')}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (flagged) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        border: Border.all(color: Colors.red.shade200),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${i.classesNeedingAttention} class(es) need attention',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.red.shade900,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEmpty(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------
  // Per-class session drill-down
  // ---------------------------------------------------------------

  void _showClassSessions(ClassOversight c) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => FutureBuilder<
            ClassSessionBreakdown>(
          future: DirectorService.fetchClassSessions(c.classId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    snapshot.error.toString().replaceFirst('Exception: ', ''),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }

            final data = snapshot.data!;
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  data.className,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                Text(
                  'Instructor: ${data.instructorName}  -  '
                  '${data.studentCount} students',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const Divider(height: 24),
                if (data.sessions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'This class has not held any attendance session yet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                else
                  ...data.sessions.map(_buildSessionRow),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSessionRow(SessionOversight s) {
    final color = _healthColor(s.health);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_healthIcon(s.health), size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              Text(
                '${s.attendanceRate}%',
                style: TextStyle(fontWeight: FontWeight.bold, color: color),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            s.dateTime,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (s.attendanceRate / 100).clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${s.checkedIn} of ${s.expected} timed in  -  '
            '${s.checkedOut} timed out'
            '${s.failed > 0 ? '  -  ${s.failed} failed' : ''}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
