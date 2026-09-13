import 'package:flutter/material.dart';

import '../../services/director_service.dart';

/// Campus oversight for the NSTP director.
///
/// Two views over the same data: "Overview" is the at-a-glance landing page
/// (totals, attendance trend, instructor performance), "By Class" lists every
/// class with the instructor assigned to it. Tapping a class opens its
/// session-by-session breakdown.
class DirectorOversightScreen extends StatefulWidget {
  /// 0 = Overview, 1 = By Class.
  final int initialTab;

  /// True when the screen is shown as a tab inside a dashboard. The title and
  /// back arrow go away, but the bar itself stays so the Overview / By Class
  /// TabBar and the refresh action remain reachable.
  final bool embedded;

  const DirectorOversightScreen({
    super.key,
    this.initialTab = 0,
    this.embedded = false,
  });

  @override
  State<DirectorOversightScreen> createState() =>
      _DirectorOversightScreenState();
}

class _DirectorOversightScreenState extends State<DirectorOversightScreen>
    with SingleTickerProviderStateMixin {
  static const Color _accent = Color(0xFFE64A19); // deepOrange 700

  /// Same bands the backend uses to colour a class "good" / "fair".
  static const double healthGood = 85;
  static const double healthFair = 70;

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
    );    _load();
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
        title: widget.embedded ? null : const Text('Attendance Oversight'),
        toolbarHeight: widget.embedded ? 48 : null,
        automaticallyImplyLeading: !widget.embedded,
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
            Tab(text: 'Overview', icon: Icon(Icons.dashboard)),
            Tab(text: 'By Class', icon: Icon(Icons.class_)),
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
        _buildOverviewTab(overview),
        _buildClassTab(overview),
      ],
    );
  }

  // ---------------------------------------------------------------
  // Tab 1: overview
  // ---------------------------------------------------------------

  Widget _buildOverviewTab(DirectorOverview overview) {
    final summary = overview.summary;
    final issues = summary.failedVerifications +
        summary.classesNeedingAttention +
        summary.classesWithoutSessions;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Director Overview',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Campus-wide attendance and instructor performance.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          _buildComponentFilter(),
          const SizedBox(height: 16),

          // 2x2 KPI grid.
          Row(
            children: [
              Expanded(
                child: _statCard(
                  icon: Icons.person,
                  color: Colors.indigo,
                  value: '${summary.totalInstructors}',
                  label: 'Instructors',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statCard(
                  icon: Icons.percent,
                  color: Colors.green,
                  value: '${summary.attendanceRate}%',
                  label: 'Attendance',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _statCard(
                  icon: Icons.event,
                  color: Colors.purple,
                  value: '${summary.totalSessions}',
                  label: 'Sessions',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statCard(
                  icon: Icons.report_problem,
                  color: Colors.red,
                  value: '$issues',
                  label: 'Issues',
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          _sectionTitle('Attendance Overview'),
          const SizedBox(height: 8),
          _buildTrendCard(overview.trend),
          const SizedBox(height: 20),

          _sectionTitle('Instructor Performance'),
          const SizedBox(height: 8),
          _buildInstructorPerformance(overview.instructors),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
    );
  }

  Widget _statCard({
    required IconData icon,
    required Color color,
    required String value,
    required String label,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrendCard(List<AttendanceTrendPoint> trend) {
    if (trend.length < 2) {
      return Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: const Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text(
              'Not enough session data yet to plot a trend.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ),
      );
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 12),
        child: SizedBox(
          height: 180,
          child: CustomPaint(
            painter: _TrendPainter(trend: trend, lineColor: _accent),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }

  Widget _buildInstructorPerformance(List<InstructorLoad> instructors) {
    if (instructors.isEmpty) {
      return _buildEmpty('No instructors have classes yet.');
    }

    final ranked = [...instructors]
      ..sort((a, b) => b.attendanceRate.compareTo(a.attendanceRate));

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: ranked.map((i) {
            final rate = i.attendanceRate.clamp(0.0, 100.0);
            final color = rate >= healthGood
                ? Colors.green
                : rate >= healthFair
                    ? Colors.amber.shade800
                    : Colors.red;

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          i.instructorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: rate / 100,
                            minHeight: 8,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: AlwaysStoppedAnimation(color),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 46,
                    child: Text(
                      '${i.attendanceRate}%',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------
  // Tab 2: by class
  // ---------------------------------------------------------------

  Widget _buildClassTab(DirectorOverview overview) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
                  Icon(Icons.person, size: 15, color: Colors.grey.shade600),
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

/// Draws the campus attendance trend as a filled line chart. Hand-rolled to
/// avoid pulling a charting dependency into the app just for this one graph.
class _TrendPainter extends CustomPainter {
  final List<AttendanceTrendPoint> trend;
  final Color lineColor;

  const _TrendPainter({required this.trend, required this.lineColor});

  static const double _leftPad = 30;
  static const double _bottomPad = 20;
  static const double _topPad = 8;
  static const double _rightPad = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final rates = trend.map((p) => p.attendanceRate).toList();
    final low = rates.reduce((a, b) => a < b ? a : b);
    final high = rates.reduce((a, b) => a > b ? a : b);

    // Give the line some breathing room, then snap the bounds to 5% steps.
    var span = high - low;
    if (span < 10) span = 10;
    final yMin = ((low - span * 0.2).clamp(0.0, 100.0) / 5).floor() * 5.0;
    final yMax = ((high + span * 0.2).clamp(0.0, 100.0) / 5).ceil() * 5.0;
    final range = (yMax - yMin).abs() < 1 ? 1.0 : (yMax - yMin);

    final plotWidth = size.width - _leftPad - _rightPad;
    final plotHeight = size.height - _topPad - _bottomPad;

    double xFor(int i) => _leftPad +
        (trend.length == 1 ? 0 : plotWidth * i / (trend.length - 1));
    double yFor(double rate) =>
        _topPad + plotHeight * (1 - (rate - yMin) / range);

    // Horizontal grid + Y labels.
    const gridLines = 4;
    final gridPaint = Paint()
      ..color = Colors.grey.shade200
      ..strokeWidth = 1;
    final labelStyle = TextStyle(fontSize: 9, color: Colors.grey.shade600);

    for (var i = 0; i <= gridLines; i++) {
      final value = yMin + range * i / gridLines;
      final y = yFor(value);
      canvas.drawLine(
        Offset(_leftPad, y),
        Offset(size.width - _rightPad, y),
        gridPaint,
      );
      _paintText(
        canvas,
        '${value.round()}%',
        Offset(0, y - 5),
        labelStyle,
        width: _leftPad - 4,
        align: TextAlign.right,
      );
    }

    // Filled area under the line.
    final linePath = Path();
    for (var i = 0; i < trend.length; i++) {
      final point = Offset(xFor(i), yFor(trend[i].attendanceRate));
      if (i == 0) {
        linePath.moveTo(point.dx, point.dy);
      } else {
        linePath.lineTo(point.dx, point.dy);
      }
    }

    final fillPath = Path.from(linePath)
      ..lineTo(xFor(trend.length - 1), _topPad + plotHeight)
      ..lineTo(xFor(0), _topPad + plotHeight)
      ..close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            lineColor.withValues(alpha: 0.28),
            lineColor.withValues(alpha: 0.02),
          ],
        ).createShader(
          Rect.fromLTWH(0, _topPad, size.width, plotHeight),
        ),
    );

    canvas.drawPath(
      linePath,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // Dots + X labels. Thin out the labels when there are many points.
    final dotPaint = Paint()..color = lineColor;
    final labelStep = (trend.length / 6).ceil().clamp(1, trend.length).toInt();
    for (var i = 0; i < trend.length; i++) {
      final point = Offset(xFor(i), yFor(trend[i].attendanceRate));
      canvas.drawCircle(point, 3, dotPaint);
      canvas.drawCircle(
        point,
        3,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

      if (i % labelStep == 0 || i == trend.length - 1) {
        _paintText(
          canvas,
          trend[i].date,
          Offset(point.dx - 16, size.height - _bottomPad + 5),
          labelStyle,
          width: 32,
          align: TextAlign.center,
        );
      }
    }
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style, {
    required double width,
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(minWidth: width, maxWidth: width);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.trend != trend || oldDelegate.lineColor != lineColor;
}
