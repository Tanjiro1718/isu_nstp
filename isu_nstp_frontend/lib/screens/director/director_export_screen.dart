import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/api_config.dart';
import '../../services/director_service.dart';

/// Director's campus-wide attendance export.
///
/// One form, five ways to slice the same data. The "Export By" choice decides
/// which filters are shown, so the director never hunts past dropdowns that do
/// not apply. Format is CSV for now; PDF/XLSX are shown but disabled so the
/// option is discoverable without pretending it works.
class DirectorExportScreen extends StatefulWidget {
  const DirectorExportScreen({super.key});

  @override
  State<DirectorExportScreen> createState() => _DirectorExportScreenState();
}

class _DirectorExportScreenState extends State<DirectorExportScreen> {
  static const Color _accent = Color(0xFF006837);

  static const _components = ['CWTS', 'LTS', 'ROTC'];

  static const _modes = <String, String>{
    'class': 'Per Class',
    'program': 'Per Program',
    'instructor': 'Per Instructor',
    'day': 'Per Day',
    'custom': 'Custom',
  };

  bool _loading = true;
  String? _error;

  List<ClassOversight> _classes = [];
  List<InstructorLoad> _instructors = [];

  String _mode = 'class';
  String? _component;
  int? _classId;
  int? _instructorId;
  DateTime? _date;
  DateTime? _dateFrom;
  DateTime? _dateTo;

  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await DirectorService.fetchOverview();
      if (!mounted) return;
      setState(() {
        _classes = overview.classes;
        _instructors = overview.instructors;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  void _resetFilters() {
    _component = null;
    _classId = null;
    _instructorId = null;
    _date = null;
    _dateFrom = null;
    _dateTo = null;
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String? _validationError() {
    switch (_mode) {
      case 'class':
        return _classId == null ? 'Choose a class to export.' : null;
      case 'program':
        return _component == null ? 'Choose a program to export.' : null;
      case 'instructor':
        return _instructorId == null ? 'Choose an instructor to export.' : null;
      case 'day':
        return _date == null ? 'Choose a date to export.' : null;
      case 'custom':
        final nothingChosen = _component == null &&
            _classId == null &&
            _instructorId == null &&
            _date == null &&
            _dateFrom == null &&
            _dateTo == null;
        return nothingChosen ? 'Choose at least one filter.' : null;
      default:
        return null;
    }
  }

  Future<void> _export() async {
    final error = _validationError();
    if (error != null) {
      _snack(error);
      return;
    }

    setState(() => _exporting = true);
    try {
      final url = ApiConfig.directorExportUrl(
        mode: _mode,
        component: _component,
        classId: _classId,
        instructorId: _instructorId,
        date: _date == null ? null : _fmt(_date!),
        dateFrom: _dateFrom == null ? null : _fmt(_dateFrom!),
        dateTo: _dateTo == null ? null : _fmt(_dateTo!),
        asCsv: true,
      );

      final response = await http
          .get(
            Uri.parse(url),
            headers: {'ngrok-skip-browser-warning': 'true'},
          )
          .timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        final tempDir = await getTemporaryDirectory();
        final filename = _filename(response) ?? 'attendance_export.csv';
        final file = File('${tempDir.path}/$filename');
        await file.writeAsBytes(response.bodyBytes);

        if (!mounted) return;
        await Share.shareXFiles(
          [XFile(file.path)],
          subject: 'Attendance Export',
        );
      } else {
        _snack(_errorMessage(response));
      }
    } catch (e) {
      _snack('Export error: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] != null) {
        return decoded['error'].toString();
      }
    } catch (_) {
      // Fall through to the status-code message.
    }
    return 'Export failed (${response.statusCode})';
  }

  String? _filename(http.Response response) {
    final disposition = response.headers['content-disposition'];
    if (disposition == null) return null;
    final match = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
    return match?.group(1);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }

    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 60),
          const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
          const SizedBox(height: 16),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          Center(
            child: FilledButton.icon(
              onPressed: _load,
              style: FilledButton.styleFrom(backgroundColor: _accent),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Export Attendance',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          'Download campus attendance for the CHED/NSTP office.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        _buildExportByCard(),
        const SizedBox(height: 12),
        _buildFiltersCard(),
        const SizedBox(height: 12),
        _buildFormatCard(),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.upload_file),
            label: Text(_exporting ? 'Preparing...' : 'Export'),
          ),
        ),
      ],
    );
  }

  Widget _buildExportByCard() {
    return _card(
      title: 'Export By',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _modes.entries
            .map((entry) => _modeTile(entry.key, entry.value))
            .toList(),
      ),
    );
  }

  Widget _modeTile(String value, String label) {
    final selected = _mode == value;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        if (_mode == value) return;
        setState(() {
          _mode = value;
          _resetFilters();
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? _accent : Colors.grey,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFiltersCard() {
    final filters = <Widget>[];
    void add(Widget widget) {
      if (filters.isNotEmpty) filters.add(const SizedBox(height: 14));
      filters.add(widget);
    }

    switch (_mode) {
      case 'class':
        add(_programField());
        add(_classField());
        break;
      case 'program':
        add(_programField(required: true));
        break;
      case 'instructor':
        add(_instructorField());
        break;
      case 'day':
        add(_dateField('Date *', _date, (d) => _date = d));
        break;
      case 'custom':
        add(_programField());
        add(_classField());
        add(_instructorField());
        add(_dateField('From', _dateFrom, (d) => _dateFrom = d));
        add(_dateField('To', _dateTo, (d) => _dateTo = d));
        break;
    }

    return _card(
      title: 'Filters',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: filters,
      ),
    );
  }

  Widget _programField({bool required = false}) {
    return _field(
      label: required ? 'Program *' : 'Program',
      child: _dropdown<String>(
        value: _component,
        hint: 'All programs',
        items: _components
            .map((c) => DropdownMenuItem(value: c, child: Text(c)))
            .toList(),
        onChanged: (value) => setState(() {
          _component = value;
          _classId = null;
        }),
      ),
    );
  }

  Widget _classField() {
    final available = _component == null
        ? _classes
        : _classes.where((c) => c.component == _component).toList();

    return _field(
      label: _mode == 'class' ? 'Class *' : 'Class',
      child: _dropdown<int>(
        value: _classId,
        hint: 'Select a class',
        items: available
            .map((c) => DropdownMenuItem(
                  value: c.classId,
                  child: Text(
                    '${c.className} — ${c.instructorName}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ))
            .toList(),
        onChanged: (value) => setState(() => _classId = value),
      ),
    );
  }

  Widget _instructorField() {
    return _field(
      label: _mode == 'instructor' ? 'Instructor *' : 'Instructor',
      child: _dropdown<int>(
        value: _instructorId,
        hint: 'Select an instructor',
        items: _instructors
            .map((i) => DropdownMenuItem(
                  value: i.instructorId,
                  child: Text(i.instructorName, overflow: TextOverflow.ellipsis),
                ))
            .toList(),
        onChanged: (value) => setState(() => _instructorId = value),
      ),
    );
  }

  Widget _dateField(String label, DateTime? value, ValueChanged<DateTime> onPick) {
    return _field(
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: value ?? DateTime.now(),
            firstDate: DateTime(2020),
            lastDate: DateTime.now().add(const Duration(days: 365)),
          );
          if (picked != null) setState(() => onPick(picked));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.calendar_today, size: 16, color: Colors.grey.shade600),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  value == null ? 'Select a date' : _fmt(value),
                  style: TextStyle(
                    fontSize: 14,
                    color: value == null ? Colors.grey.shade600 : Colors.black87,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFormatCard() {
    return _card(
      title: 'Format',
      child: _dropdown<String>(
        value: 'csv',
        items: const [
          DropdownMenuItem(value: 'csv', child: Text('CSV')),
          DropdownMenuItem(
            value: 'pdf',
            enabled: false,
            child: Text('PDF (coming soon)'),
          ),
          DropdownMenuItem(
            value: 'xlsx',
            enabled: false,
            child: Text('XLSX (coming soon)'),
          ),
        ],
        onChanged: (_) {},
      ),
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _field({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _dropdown<T>({
    required T? value,
    String hint = '',
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          hint: hint.isEmpty
              ? null
              : Text(
                  hint,
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                ),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
