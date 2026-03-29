import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../bloc/login/login_cubit.dart';
import 'login_screen.dart';

// ─── theme ───────────────────────────────────────────────────────────────────
const _kBg        = Color(0xfff0f4f8);
const _kBlue      = Color(0xff1565c0);
const _kBlueLight = Color(0xff42a5f5);
const _kOrange    = Color(0xffff9800);
const _kGreen     = Color(0xff43a047);
const _kRed       = Color(0xffe53935);
const _kTextDark  = Color(0xff1a2340);
const _kTextMid   = Color(0xff5a6a85);
const _kDivider   = Color(0xffe8edf3);

const int _kEscalationThreshold = 20;
const int _kMaxWorkerJobs       = 10;

// ─── icon helper ─────────────────────────────────────────────────────────────
IconData _issueIcon(String? name) {
  final n = (name ?? '').toLowerCase();
  if (n.contains('road') || n.contains('pothole')) return Icons.route_rounded;
  if (n.contains('water') || n.contains('drain') || n.contains('sewage'))
    return Icons.water_drop_rounded;
  if (n.contains('light') || n.contains('electric') || n.contains('lamp'))
    return Icons.lightbulb_rounded;
  if (n.contains('garbage') || n.contains('waste') || n.contains('trash'))
    return Icons.delete_rounded;
  if (n.contains('tree') || n.contains('park')) return Icons.park_rounded;
  if (n.contains('building') || n.contains('struct'))
    return Icons.apartment_rounded;
  if (n.contains('noise') || n.contains('sound'))
    return Icons.volume_up_rounded;
  if (n.contains('animal') || n.contains('stray')) return Icons.pets_rounded;
  return Icons.report_problem_rounded;
}

// ─── screen ──────────────────────────────────────────────────────────────────
class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});
  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen>
    with SingleTickerProviderStateMixin {
  final _db = Supabase.instance.client;

  List<Map<String, dynamic>> _allComplaints    = [];
  List<Map<String, dynamic>> _activeComplaints = [];
  Map<String, dynamic>?      _adminData;
  bool    _isLoading  = true;
  String? _error;
  // Removed _filter, use _tabCtrl.index instead
  String  _searchQ    = '';

  late final TabController _tabCtrl;
  final _searchCtrl = TextEditingController();

  static const Map<String, int> _pLevel = {
    'low': 1, 'medium': 2, 'high': 3, 'critical': 4,
  };
  static const List<String> _pLabels = ['low', 'medium', 'high', 'critical'];

  // ── lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: _kBlue,
      statusBarIconBrightness: Brightness.light,
    ));
    _tabCtrl = TabController(length: 4, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── data ─────────────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final prefs   = await SharedPreferences.getInstance();
      final adminId = prefs.getString('admin_id');
      if (adminId == null) throw Exception('Session expired. Please log in again.');

      final admin = await _db.from('admin').select().eq('id', adminId).single();
      _adminData = admin;
      final wardId = admin['ward_id'];

      List byCode = await _db
          .from('complaints')
          .select()
          .eq('ward_code', wardId)
          .order('created_at', ascending: false);

      late final List raw;
      if (byCode.isNotEmpty) {
        raw = byCode;
      } else {
        final ward = await _db
            .from('wards')
            .select('min_lat, max_lat, min_lng, max_lng')
            .eq('id', wardId)
            .maybeSingle();
        if (ward != null) {
          raw = await _db
              .from('complaints')
              .select()
              .gte('latitude',  (ward['min_lat'] as num).toDouble())
              .lte('latitude',  (ward['max_lat'] as num).toDouble())
              .gte('longitude', (ward['min_lng'] as num).toDouble())
              .lte('longitude', (ward['max_lng'] as num).toDouble())
              .order('created_at', ascending: false);
        } else {
          raw = byCode;
        }
      }

      final all    = List<Map<String, dynamic>>.from(raw);
      final active = all
          .where((c) => c['status'] != 'closed')
          .map((c) => Map<String, dynamic>.from(c))
          .toList();

      await _escalate(active);

      final deduped = _deduplicate(active);
      deduped.sort((a, b) =>
          (_pLevel[b['priority']] ?? 0).compareTo(_pLevel[a['priority']] ?? 0));

      final escalatedIds = {for (final c in active) c['id']: c['priority']};
      final allUpdated = all.map((c) {
        if (escalatedIds.containsKey(c['id'])) {
          return Map<String, dynamic>.from(c)
            ..['priority'] = escalatedIds[c['id']];
        }
        return c;
      }).toList();

      setState(() {
        _allComplaints    = allUpdated;
        _activeComplaints = deduped;
        _isLoading        = false;
      });
    } catch (e) {
      setState(() {
        _error     = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> _deduplicate(List<Map<String, dynamic>> list) {
    final seen   = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final c in list) {
      final uid = c['user_id'] as String? ?? '';
      final lat = (c['latitude']  as num?)?.toStringAsFixed(3) ?? 'x';
      final lng = (c['longitude'] as num?)?.toStringAsFixed(3) ?? 'x';
      final key = '${uid}_${lat}_$lng';
      if (uid.isEmpty || seen.add(key)) result.add(c);
    }
    return result;
  }

  Future<void> _escalate(List<Map<String, dynamic>> list) async {
    if (list.isEmpty) return;
    final Map<String, List<Map<String, dynamic>>> groups = {};
    for (final c in list) {
      final lat = (c['latitude']  as num?)?.toStringAsFixed(3) ?? 'x';
      final lng = (c['longitude'] as num?)?.toStringAsFixed(3) ?? 'x';
      groups.putIfAbsent('${c['issue_name']}_${lat}_$lng', () => []).add(c);
    }
    for (final group in groups.values) {
      if (group.length < _kEscalationThreshold) continue;
      final maxLv    = group.map((c) => _pLevel[c['priority']] ?? 1).reduce(max);
      final newLv    = min(maxLv + 1, 4);
      final newLabel = _pLabels[newLv - 1];
      for (final c in group) {
        if ((_pLevel[c['priority']] ?? 1) < newLv) {
          c['priority'] = newLabel;
          try {
            await _db.from('complaints')
                .update({'priority': newLabel}).eq('id', c['id'] as Object);
          } catch (_) {}
        }
      }
    }
  }

  // ── computed ─────────────────────────────────────────────────────────────

  int get _totalCount   => _allComplaints.length;
  int get _openCount    => _allComplaints.where((c) => c['status'] == 'open').length;
  int get _progressCount => _allComplaints.where((c) => c['status'] == 'progress').length;
  int get _closedCount  => _allComplaints.where((c) => c['status'] == 'closed').length;

  // Removed _filtered getter, use _tabCtrl.index in _buildMainContent TabBarView

  // ── assign ───────────────────────────────────────────────────────────────

  Future<void> _assignComplaint(Map<String, dynamic> complaint) async {
    final wardId = _adminData?['ward_id'];

    List<Map<String, dynamic>> workers = [];
    String? fetchErr;
    try {
      final raw = await _db
          .from('workers')
          .select('id, name, phone')
          .eq('ward_no', wardId)
          .eq('is_available', true)
          .order('name');
      workers = List<Map<String, dynamic>>.from(raw as List);
    } catch (e) {
      fetchErr = e.toString();
    }

    if (!mounted) return;

    Map<String, dynamic>? selected;
    final pick = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, ss) => Dialog(
          backgroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          elevation: 8,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Assign Complaint',
                      style: GoogleFonts.poppins(
                          color: _kTextDark,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const SizedBox(height: 14),
                  _chip(complaint['issue_name'] as String? ?? 'Issue',
                      _issueIcon(complaint['issue_name'] as String?)),
                  const SizedBox(height: 16),
                  if (fetchErr != null)
                    _alertBox('Workers fetch error: $fetchErr', _kRed)
                  else if (workers.isEmpty)
                    _alertBox('No available workers in this ward.', _kOrange,
                        icon: Icons.warning_amber_rounded)
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Available Workers',
                            style: GoogleFonts.poppins(
                                color: _kTextMid,
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: _kBg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _kDivider),
                          ),
                          padding:
                              const EdgeInsets.symmetric(horizontal: 14),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<Map<String, dynamic>>(
                              isExpanded: true,
                              hint: Text('Choose a worker…',
                                  style: GoogleFonts.poppins(
                                      color: _kTextMid, fontSize: 13)),
                              value: selected,
                              dropdownColor: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              items: workers.map((w) {
                                return DropdownMenuItem<
                                    Map<String, dynamic>>(
                                  value: w,
                                  child: Row(children: [
                                    Container(
                                      padding: const EdgeInsets.all(7),
                                      decoration: BoxDecoration(
                                        color: _kBlue.withOpacity(0.1),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                          Icons.engineering_rounded,
                                          color: _kBlue,
                                          size: 14),
                                    ),
                                    const SizedBox(width: 10),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(w['name'] as String,
                                            style: GoogleFonts.poppins(
                                                color: _kTextDark,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600)),
                                        if (w['phone'] != null)
                                          Text(w['phone'] as String,
                                              style: GoogleFonts.poppins(
                                                  color: _kTextMid,
                                                  fontSize: 11)),
                                      ],
                                    ),
                                  ]),
                                );
                              }).toList(),
                              onChanged: (v) => ss(() => selected = v),
                            ),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _cancelBtn(() => Navigator.pop(ctx)),
                      if (workers.isNotEmpty)
                        _primaryBtn(
                          'Assign',
                          selected == null ? null : () => Navigator.pop(ctx, selected),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (pick != null) {
      try {
        // Capacity check
        final active = (await _db
            .from('complaints')
            .select('id')
            .eq('assigned_worker_id', pick['id'] as Object)
            .eq('status', 'progress')) as List;
        if (active.length >= _kMaxWorkerJobs) {
          if (mounted) {
            _snack(
                '${pick['name']} already has ${active.length} active jobs (max $_kMaxWorkerJobs).',
                _kOrange);
          }
          return;
        }
        final dueDate = DateTime.now().add(const Duration(days: 5));
        final dueDateStr =
            '${dueDate.year}-${dueDate.month.toString().padLeft(2, '0')}-${dueDate.day.toString().padLeft(2, '0')}';
        await _db.from('complaints').update({
          'assigned_to':        pick['name'] as String,
          'assigned_worker_id': pick['id'],
          'status':             'progress',
          'deadline':           dueDateStr,
        }).eq('id', complaint['id'] as Object);
        _loadData();
      } catch (e) {
        if (mounted) _snack('Assign failed: $e', _kRed);
      }
    }
  }

  Future<void> _closeComplaint(Map<String, dynamic> c) async {
    final issue = (c['issue_name'] as String? ?? 'complaint').toUpperCase();
    final ok = await _dlg<bool>(
      title: 'Resolve Complaint',
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _chip(c['issue_name'] as String? ?? 'Issue',
            _issueIcon(c['issue_name'] as String?)),
        const SizedBox(height: 12),
        Text('Mark "$issue" as resolved?\nThis cannot be undone.',
            style: GoogleFonts.poppins(
                color: _kTextMid, fontSize: 13, height: 1.5)),
      ]),
      actions: [
        _cancelBtn(() => Navigator.pop(context, false)),
        _primaryBtn('Resolve ✓', () => Navigator.pop(context, true),
            color: _kGreen),
      ],
    );
    if (ok == true) {
      await _db.from('complaints')
          .update({'status': 'closed'}).eq('id', c['id'] as Object);
      _loadData();
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => BlocProvider(
          create: (_) => AuthCubit(),
          child: const AdminLoginScreen(),
        ),
      ),
    );
  }

  // ── dialog helpers ───────────────────────────────────────────────────────

  Future<T?> _dlg<T>({
    required String title,
    required Widget child,
    required List<Widget> actions,
  }) {
    return showDialog<T>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 8,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.poppins(
                        color: _kTextDark,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
                const SizedBox(height: 16),
                child,
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _alertBox(String msg, Color color,
      {IconData icon = Icons.error_outline_rounded}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(
            child: Text(msg,
                style: GoogleFonts.poppins(color: color, fontSize: 11))),
      ]),
    );
  }

  Widget _chip(String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _kBlue.withOpacity(0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kBlue.withOpacity(0.2)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: _kBlue, size: 16),
        const SizedBox(width: 8),
        Text(label.toUpperCase(),
            style: GoogleFonts.poppins(
                color: _kBlue, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _cancelBtn(VoidCallback fn) => TextButton(
        onPressed: fn,
        child: Text('Cancel',
            style: GoogleFonts.poppins(color: _kTextMid, fontSize: 13)),
      );

  Widget _primaryBtn(String label, VoidCallback? fn,
      {Color color = _kBlue}) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: ElevatedButton(
        onPressed: fn,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          elevation: 0,
        ),
        child: Text(label,
            style: GoogleFonts.poppins(
                fontWeight: FontWeight.w600, fontSize: 13)),
      ),
    );
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.poppins(fontSize: 12)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── colour/label helpers ─────────────────────────────────────────────────

  Color _pColor(String? p) {
    switch (p) {
      case 'critical': return _kRed;
      case 'high':     return const Color(0xffff5722);
      case 'medium':   return _kOrange;
      default:         return _kGreen;
    }
  }

  Color _sColor(String? s) {
    switch (s) {
      case 'closed':   return _kGreen;
      case 'progress': return _kBlue;
      default:         return _kOrange;
    }
  }

  String _sLabel(String? s) {
    switch (s) {
      case 'open':     return 'OPEN';
      case 'progress': return 'IN PROGRESS';
      case 'closed':   return 'CLOSED';
      default:         return (s ?? '').toUpperCase();
    }
  }

  // ─── BUILD ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final wardId    = _adminData?['ward_id'] ?? '--';
    final adminName = _adminData?['name'] as String?
        ?? _adminData?['mobile_number'] as String?
        ?? 'Admin';

    return Scaffold(
      backgroundColor: _kBg,
      drawer: _buildDrawer(adminName, wardId),
      body: _isLoading
          ? _buildLoader()
          : _error != null
              ? _buildError()
              : LayoutBuilder(builder: (ctx, c) {
                  return c.maxWidth >= 900
                      ? _buildWide(wardId, adminName)
                      : _buildNarrow(wardId, adminName);
                }),
    );
  }

  // ─── DRAWER ──────────────────────────────────────────────────────────────

  Widget _buildDrawer(String adminName, dynamic wardId) {
    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(children: [
          // header
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                  colors: [_kBlueLight, _kBlue],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight),
            ),
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: Colors.white.withOpacity(0.25),
                child: const Icon(Icons.admin_panel_settings_rounded,
                    color: Colors.white, size: 32),
              ),
              const SizedBox(height: 12),
              Text(adminName,
                  style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16)),
              const SizedBox(height: 3),
              Row(children: [
                const Icon(Icons.location_on_rounded, size: 13, color: Colors.white70),
                const SizedBox(width: 4),
                Text('Ward $wardId',
                    style: GoogleFonts.poppins(
                        color: Colors.white70, fontSize: 12)),
              ]),
            ]),
          ),
          const SizedBox(height: 8),
          // stats mini-summary
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _kBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kDivider),
              ),
              child: Column(children: [
                _drawerStat(Icons.circle_notifications_rounded,
                    'Open', _openCount, _kOrange),
                const Divider(height: 16),
                _drawerStat(Icons.pending_rounded, 'In Progress',
                    _progressCount, _kBlue),
                const Divider(height: 16),
                _drawerStat(Icons.check_circle_rounded, 'Resolved',
                    _closedCount, _kGreen),
              ]),
            ),
          ),
          const Divider(height: 1),
          _drawerTile(Icons.refresh_rounded, 'Refresh Data', _loadData),
          const Spacer(),
          const Divider(height: 1),
          _drawerTile(Icons.logout_rounded, 'Logout', _logout,
              color: _kRed),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _drawerStat(IconData icon, String label, int value, Color color) {
    return Row(children: [
      Icon(icon, color: color, size: 16),
      const SizedBox(width: 10),
      Text(label,
          style: GoogleFonts.poppins(color: _kTextMid, fontSize: 12)),
      const Spacer(),
      Text(value.toString(),
          style: GoogleFonts.poppins(
              color: color, fontWeight: FontWeight.w700, fontSize: 14)),
    ]);
  }

  Widget _drawerTile(IconData icon, String label, VoidCallback fn,
      {Color? color}) {
    return ListTile(
      leading: Icon(icon, color: color ?? _kTextMid, size: 22),
      title: Text(label,
          style: GoogleFonts.poppins(
              color: color ?? _kTextDark, fontSize: 14)),
      dense: true,
      onTap: () { Navigator.pop(context); fn(); },
    );
  }

  // ─── WIDE LAYOUT ─────────────────────────────────────────────────────────

  Widget _buildWide(dynamic wardId, String adminName) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 270, child: _buildSidebar(adminName, wardId)),
      Container(width: 1, color: _kDivider),
      Expanded(child: _buildMainContent()),
    ]);
  }

  Widget _buildSidebar(String adminName, dynamic wardId) {
    return Container(
      color: Colors.white,
      child: Column(children: [
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                colors: [_kBlueLight, _kBlue],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
          ),
          padding: const EdgeInsets.fromLTRB(20, 48, 20, 28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Image.asset('images/icon.png', height: 36),
            ),
            const SizedBox(height: 12),
            Text('Admin Dashboard',
                style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 17)),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.person_rounded, size: 13, color: Colors.white70),
              const SizedBox(width: 4),
              Flexible(
                child: Text(adminName,
                    style: GoogleFonts.poppins(
                        color: Colors.white70, fontSize: 12),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
            const SizedBox(height: 2),
            Row(children: [
              const Icon(Icons.location_on_rounded, size: 13, color: Colors.white70),
              const SizedBox(width: 4),
              Text('Ward $wardId',
                  style: GoogleFonts.poppins(
                      color: Colors.white70, fontSize: 12)),
            ]),
          ]),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: [
            _sidebarStat('Open', _openCount, _kOrange,
                Icons.circle_notifications_rounded),
            const SizedBox(height: 8),
            _sidebarStat('In Progress', _progressCount, _kBlue,
                Icons.pending_rounded),
            const SizedBox(height: 8),
            _sidebarStat('Resolved', _closedCount, _kGreen,
                Icons.check_circle_rounded),
            const SizedBox(height: 8),
            _sidebarStat('Total', _totalCount, _kTextMid,
                Icons.layers_rounded),
          ]),
        ),
        const SizedBox(height: 8),
        const Divider(color: _kDivider, indent: 16, endIndent: 16),
        _drawerTile(Icons.refresh_rounded, 'Refresh Data', _loadData),
        const Spacer(),
        const Divider(color: _kDivider, indent: 16, endIndent: 16),
        _drawerTile(Icons.logout_rounded, 'Logout', _logout, color: _kRed),
        const SizedBox(height: 16),
      ]),
    );
  }

  Widget _sidebarStat(String label, int value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(
            child: Text(label,
                style:
                    GoogleFonts.poppins(color: _kTextMid, fontSize: 12))),
        Text(value.toString(),
            style: GoogleFonts.poppins(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 18)),
      ]),
    );
  }

  // ─── NARROW LAYOUT ───────────────────────────────────────────────────────

  Widget _buildNarrow(dynamic wardId, String adminName) {
    return Column(
      children: [
        Stack(clipBehavior: Clip.none, children: [
          _buildHeader(wardId, adminName),
          Positioned(
            bottom: -48,
            left: 0,
            right: 0,
            child: _buildStatRow(),
          ),
        ]),
        const SizedBox(height: 56),
        _buildSearch(),
        _buildTabs(),
        Expanded(
          child: RefreshIndicator(
            color: _kBlue,
            onRefresh: _loadData,
            child: TabBarView(
              controller: _tabCtrl,
              physics: const BouncingScrollPhysics(),
              children: [
                _buildComplaintsList(_activeComplaints),
                _buildComplaintsList(_activeComplaints.where((c) => c['status'] == 'open').toList()),
                _buildComplaintsList(_activeComplaints.where((c) => c['status'] == 'progress').toList()),
                _buildComplaintsList(_allComplaints.where((c) => c['status'] == 'closed').toList()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMainContent() {
    return RefreshIndicator(
      color: _kBlue,
      onRefresh: _loadData,
      child: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 16),
            child: Row(children: [
              Text('Complaints',
                  style: GoogleFonts.poppins(
                      color: _kTextDark,
                      fontWeight: FontWeight.w700,
                      fontSize: 22)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: _kBlue),
                onPressed: _loadData,
                tooltip: 'Refresh',
              ),
            ]),
          ),
          _buildSearch(),
          _buildTabs(),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              physics: const BouncingScrollPhysics(),
              children: [
                // All Active
                _buildComplaintsList(_activeComplaints),
                // Pending
                _buildComplaintsList(_activeComplaints.where((c) => c['status'] == 'open').toList()),
                // In Progress
                _buildComplaintsList(_activeComplaints.where((c) => c['status'] == 'progress').toList()),
                // Resolved
                _buildComplaintsList(_allComplaints.where((c) => c['status'] == 'closed').toList()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComplaintsList(List<Map<String, dynamic>> complaints) {
    final filtered = _searchQ.isNotEmpty
        ? complaints.where((c) {
            final id    = (c['complaint_id'] as String? ?? '').toLowerCase();
            final issue = (c['issue_name']   as String? ?? '').toLowerCase();
            final desc  = (c['description']  as String? ?? '').toLowerCase();
            final q     = _searchQ.toLowerCase();
            return id.contains(q) || issue.contains(q) || desc.contains(q);
          }).toList()
        : complaints;
    if (filtered.isEmpty) {
      return _buildEmpty();
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      itemCount: filtered.length,
      itemBuilder: (_, i) => _buildCard(filtered[i]),
    );
  }

  // ── HEADER (narrow) ───────────────────────────────────────────────────────

  Widget _buildHeader(dynamic wardId, String adminName) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            colors: [_kBlueLight, _kBlue],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 12, 60),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Builder(builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu_rounded, color: Colors.white),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
                tooltip: 'Menu',
              )),
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.18),
                  shape: BoxShape.circle,
                ),
                child: Image.asset('images/icon.png', height: 32),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Admin Dashboard',
                          style: GoogleFonts.poppins(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                      const SizedBox(height: 2),
                      Row(children: [
                        const Icon(Icons.location_on_rounded,
                            size: 12, color: Colors.white70),
                        const SizedBox(width: 3),
                        Text('Ward $wardId',
                            style: GoogleFonts.poppins(
                                fontSize: 11, color: Colors.white70)),
                      ]),
                    ]),
              ),
              IconButton(
                icon: const Icon(Icons.logout_rounded, color: Colors.white),
                onPressed: _logout,
                tooltip: 'Logout',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── STAT ROW ──────────────────────────────────────────────────────────────

  Widget _buildStatRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _StatData('Open', _openCount, Icons.circle_notifications_rounded, _kOrange),
          _StatData('In Progress', _progressCount, Icons.pending_rounded, _kBlue),
          _StatData('Resolved', _closedCount, Icons.check_circle_rounded, _kGreen),
          _StatData('Total', _totalCount, Icons.layers_rounded, _kTextMid),
        ]
            .map((s) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                              blurRadius: 10,
                              color: Colors.black.withOpacity(0.07),
                              offset: const Offset(0, 4))
                        ],
                      ),
                      child: Column(children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: s.color.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(s.icon, color: s.color, size: 15),
                        ),
                        const SizedBox(height: 5),
                        Text(s.value.toString(),
                            style: GoogleFonts.poppins(
                                color: s.color,
                                fontSize: 18,
                                fontWeight: FontWeight.w800)),
                        Text(s.label,
                            style: GoogleFonts.poppins(
                                color: _kTextMid,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w500),
                            textAlign: TextAlign.center,
                            maxLines: 2),
                      ]),
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }

  // ── SEARCH ────────────────────────────────────────────────────────────────

  Widget _buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _searchQ = v.trim()),
        style: GoogleFonts.poppins(color: _kTextDark, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Search by ID, issue type…',
          hintStyle: GoogleFonts.poppins(color: _kTextMid, fontSize: 13),
          prefixIcon:
              const Icon(Icons.search_rounded, color: _kBlue, size: 20),
          suffixIcon: _searchQ.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear_rounded,
                      color: _kTextMid, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _searchQ = '');
                  },
                )
              : null,
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: _kDivider)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: _kDivider)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: _kBlue, width: 1.5)),
        ),
      ),
    );
  }

  // ── TABS ──────────────────────────────────────────────────────────────────

  Widget _buildTabs() {
    const labels = ['All Active', 'Pending', 'In Progress', 'Resolved'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Complaints',
              style: GoogleFonts.poppins(
                  color: _kTextDark,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('sorted by priority ↓',
              style: GoogleFonts.poppins(
                  color: _kTextMid, fontSize: 11, fontStyle: FontStyle.italic)),
        ]),
        const SizedBox(height: 10),
        AnimatedBuilder(
          animation: _tabCtrl,
          builder: (_, __) {
            final selected = _tabCtrl.index;
            return Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(blurRadius: 6, color: Colors.black.withOpacity(0.05))
                ],
              ),
              child: Row(
                children: List.generate(labels.length, (i) {
                  final isSelected = selected == i;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _tabCtrl.index = i;
                        });
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        decoration: BoxDecoration(
                          color: isSelected ? _kBlue : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          labels[i],
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: isSelected ? Colors.white : _kTextMid,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            );
          },
        ),
      ]),
    );
  }

  // ── CARD ──────────────────────────────────────────────────────────────────

  Widget _buildCard(Map<String, dynamic> c) {
    final priority    = c['priority']    as String? ?? 'low';
    final status      = c['status']      as String? ?? 'open';
    final assignedTo  = c['assigned_to'] as String?;
    final complaintId = c['complaint_id'] as String?;
    final issueName   = c['issue_name']  as String? ?? 'Unknown';
    final pc = _pColor(priority);
    final sc = _sColor(status);

    final createdAt = c['created_at'] != null
        ? DateTime.tryParse(c['created_at'].toString())?.toLocal()
        : null;
    final deadline = c['deadline'] != null
        ? DateTime.tryParse(c['deadline'].toString())?.toLocal()
        : null;
    final isOverdue = deadline != null &&
        deadline.isBefore(DateTime.now()) &&
        status != 'closed';
    final hasImage = (c['image_url'] as String? ?? '').isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              blurRadius: 12,
              color: Colors.black.withOpacity(0.07),
              offset: const Offset(0, 4))
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Priority bar
        Container(
          height: 4,
          decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: [pc, pc.withOpacity(0.3)]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Complaint ID
                if (complaintId != null) ...[
                  Text(complaintId,
                      style: GoogleFonts.poppins(
                          color: _kTextMid,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5)),
                  const SizedBox(height: 4),
                ],
                // Title row
                Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: pc.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(_issueIcon(issueName), color: pc, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 2),
                            Text(issueName,
                                style: GoogleFonts.poppins(
                                    color: _kTextDark,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14)),
                            const SizedBox(height: 6),
                            Wrap(spacing: 5, runSpacing: 4, children: [
                              _badge(priority.toUpperCase(), pc),
                              _badge(_sLabel(status), sc),
                              if (isOverdue) _badge('OVERDUE', _kRed),
                            ]),
                          ],
                        ),
                      ),
                      if (hasImage) ...[
                        const SizedBox(width: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.network(
                            c['image_url'] as String,
                            width: 54,
                            height: 54,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                      ],
                    ]),
                // Description
                if ((c['description'] as String? ?? '').isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    c['description'] as String,
                    style: GoogleFonts.poppins(
                        color: _kTextMid, fontSize: 12, height: 1.5),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                // Meta
                const SizedBox(height: 10),
                Wrap(spacing: 14, runSpacing: 6, children: [
                  if ((c['address'] as String? ?? '').isNotEmpty)
                    _meta(Icons.location_on_rounded, c['address'] as String),
                  if (assignedTo != null && assignedTo.isNotEmpty)
                    _meta(Icons.engineering_rounded, assignedTo,
                        color: _kBlue),
                  if (deadline != null)
                    _meta(
                      Icons.timer_rounded,
                      'Due: ${deadline.day}/${deadline.month}/${deadline.year}',
                      color: isOverdue ? _kRed : _kTextMid,
                    ),
                  if (createdAt != null)
                    _meta(
                      Icons.access_time_rounded,
                      '${createdAt.day}/${createdAt.month}/${createdAt.year}'
                      '  ${createdAt.hour.toString().padLeft(2, '0')}:'
                      '${createdAt.minute.toString().padLeft(2, '0')}',
                    ),
                ]),
                // Show rating and review if resolved and rating exists
                if (status == 'closed' && c['rating'] != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.star_rounded, color: Colors.amber, size: 18),
                      const SizedBox(width: 6),
                      Text('Rating: ',
                          style: GoogleFonts.poppins(
                              color: _kTextMid,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                      Text(c['rating'].toString(),
                          style: GoogleFonts.poppins(
                              color: _kTextDark,
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                  if (c['review'] != null && (c['review'] as String).trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.comment_rounded, color: _kBlue, size: 16),
                        const SizedBox(width: 6),
                        Text('Review: ',
                            style: GoogleFonts.poppins(
                                color: _kTextMid,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                        Expanded(
                          child: Text(
                            c['review'],
                            style: GoogleFonts.poppins(
                                color: _kTextDark,
                                fontSize: 12,
                                fontWeight: FontWeight.w400),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                Divider(color: _kDivider, height: 1),
                const SizedBox(height: 10),
                // Buttons (hide for resolved)
                if (status != 'closed')
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _assignComplaint(c),
                        icon: const Icon(Icons.person_add_alt_1_rounded,
                            size: 14),
                        label: Text(
                          (assignedTo != null && assignedTo.isNotEmpty)
                              ? 'Reassign'
                              : 'Assign',
                          style: GoogleFonts.poppins(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _kBlue,
                          side: BorderSide(color: _kBlue.withOpacity(0.5)),
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () => _closeComplaint(c),
                        icon: const Icon(
                            Icons.check_circle_outline_rounded,
                            size: 14),
                        label: Text('Resolve',
                            style: GoogleFonts.poppins(
                                fontSize: 12, fontWeight: FontWeight.w600)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kGreen,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ]),
              ]),
        ),
      ]),
    );
  }

  // ── LOADER / ERROR / EMPTY ────────────────────────────────────────────────

  Widget _buildLoader() {
    return Container(
      color: _kBg,
      child: Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const CircularProgressIndicator(color: _kBlue),
        const SizedBox(height: 16),
        Text('Loading complaints…',
            style: GoogleFonts.poppins(color: _kTextMid, fontSize: 13)),
      ])),
    );
  }

  Widget _buildError() {
    return Container(
      color: _kBg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child:
              Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                  color: _kRed.withOpacity(0.1), shape: BoxShape.circle),
              child:
                  const Icon(Icons.wifi_off_rounded, color: _kRed, size: 40),
            ),
            const SizedBox(height: 16),
            Text(_error!,
                style: GoogleFonts.poppins(color: _kRed, fontSize: 14),
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh_rounded),
              label: Text('Retry',
                  style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _kBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 28, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Container(
      color: _kBg,
      child: Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: _kGreen.withOpacity(0.1), shape: BoxShape.circle),
          child: const Icon(Icons.check_circle_rounded,
              color: _kGreen, size: 44),
        ),
        const SizedBox(height: 16),
        Text('All clear!',
            style: GoogleFonts.poppins(
                color: _kTextDark,
                fontSize: 18,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('No complaints in this category',
            style: GoogleFonts.poppins(color: _kTextMid, fontSize: 13)),
      ])),
    );
  }

  // ── tiny widgets ─────────────────────────────────────────────────────────

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(label,
          style: GoogleFonts.poppins(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.3)),
    );
  }

  Widget _meta(IconData icon, String text, {Color color = _kTextMid}) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 12, color: color),
      const SizedBox(width: 4),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: Text(text,
            style: GoogleFonts.poppins(fontSize: 11, color: color),
            overflow: TextOverflow.ellipsis,
            maxLines: 1),
      ),
    ]);
  }
}

// ─── tiny data holder ────────────────────────────────────────────────────────
class _StatData {
  final String   label;
  final int      value;
  final IconData icon;
  final Color    color;
  const _StatData(this.label, this.value, this.icon, this.color);
}
