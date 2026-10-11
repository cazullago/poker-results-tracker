import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const PokerResultsApp());
}

const List<String> gameTypes = ['NLHE', 'PLO', 'PLO5', 'Mixed'];
const List<String> filterOptions = ['All', 'NLHE', 'PLO', 'PLO5', 'Mixed'];

// ---------- helpers ----------

String formatMoney(double value, String currency) {
  final neg = value < 0;
  final abs = value.abs();
  final whole = abs.truncate().toString();
  final buf = StringBuffer();
  for (int i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
    buf.write(whole[i]);
  }
  return '${neg ? '-' : ''}$currency$buf';
}

String shortMoney(double value, String currency) {
  final a = value.abs();
  String core;
  if (a >= 1000000) {
    core = '${(value / 1000000).toStringAsFixed(1)}M';
  } else if (a >= 1000) {
    core = '${(value / 1000).toStringAsFixed(a >= 10000 ? 0 : 1)}k';
  } else {
    core = value.toStringAsFixed(0);
  }
  return '$currency$core';
}

String formatDate(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

String formatHours(double h) {
  if (h == h.truncateToDouble()) return h.toStringAsFixed(0);
  return h.toStringAsFixed(1);
}

// ---------- data model ----------

class PokerSession {
  final String id;
  final DateTime date;
  final String location;
  final String game;
  final String stakes;
  final double buyIn;
  final double cashOut;
  final double hours;
  final String notes;

  PokerSession({
    required this.id,
    required this.date,
    required this.location,
    required this.game,
    required this.stakes,
    required this.buyIn,
    required this.cashOut,
    required this.hours,
    required this.notes,
  });

  double get profit => cashOut - buyIn;

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'location': location,
        'game': game,
        'stakes': stakes,
        'buyIn': buyIn,
        'cashOut': cashOut,
        'hours': hours,
        'notes': notes,
      };

  factory PokerSession.fromJson(Map<String, dynamic> j) => PokerSession(
        id: j['id'] as String,
        date: DateTime.parse(j['date'] as String),
        location: j['location'] as String? ?? '',
        game: j['game'] as String? ?? 'NLHE',
        stakes: j['stakes'] as String? ?? '',
        buyIn: (j['buyIn'] as num).toDouble(),
        cashOut: (j['cashOut'] as num).toDouble(),
        hours: (j['hours'] as num?)?.toDouble() ?? 0,
        notes: j['notes'] as String? ?? '',
      );
}

// ---------- store ----------

class SessionStore extends ChangeNotifier {
  List<PokerSession> sessions = [];
  String currency = '₱';
  bool loaded = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    currency = prefs.getString('currency') ?? '₱';
    final raw = prefs.getString('sessions');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        sessions = list
            .map((e) => PokerSession.fromJson(e as Map<String, dynamic>))
            .toList();
        sessions.sort((a, b) => b.date.compareTo(a.date));
      } catch (_) {
        sessions = [];
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currency', currency);
    await prefs.setString(
        'sessions', jsonEncode(sessions.map((s) => s.toJson()).toList()));
  }

  Future<void> addSession(PokerSession s) async {
    sessions.add(s);
    sessions.sort((a, b) => b.date.compareTo(a.date));
    notifyListeners();
    await _persist();
  }

  Future<void> updateSession(PokerSession s) async {
    final i = sessions.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      sessions[i] = s;
      sessions.sort((a, b) => b.date.compareTo(a.date));
      notifyListeners();
      await _persist();
    }
  }

  Future<void> removeSession(String id) async {
    sessions.removeWhere((e) => e.id == id);
    notifyListeners();
    await _persist();
  }

  Future<void> setCurrency(String c) async {
    currency = c.trim().isEmpty ? '₱' : c.trim();
    notifyListeners();
    await _persist();
  }

  Future<void> clearAll() async {
    sessions = [];
    notifyListeners();
    await _persist();
  }
}

final SessionStore store = SessionStore();

// ---------- stats ----------

class SessionStats {
  final double totalProfit;
  final int count;
  final double hours;
  final double hourly;
  final double winRate;
  final double best;
  final double worst;
  final List<double> cumulative; // oldest -> newest
  final List<double> profits; // oldest -> newest
  final List<String> labels; // oldest -> newest

  SessionStats({
    required this.totalProfit,
    required this.count,
    required this.hours,
    required this.hourly,
    required this.winRate,
    required this.best,
    required this.worst,
    required this.cumulative,
    required this.profits,
    required this.labels,
  });
}

SessionStats computeStats(List<PokerSession> sessions) {
  final asc = List<PokerSession>.from(sessions)
    ..sort((a, b) => a.date.compareTo(b.date));
  double cum = 0;
  double hours = 0;
  int wins = 0;
  double best = 0;
  double worst = 0;
  final cumulative = <double>[];
  final profits = <double>[];
  final labels = <String>[];
  for (int i = 0; i < asc.length; i++) {
    final s = asc[i];
    cum += s.profit;
    cumulative.add(cum);
    profits.add(s.profit);
    labels.add(formatDate(s.date));
    hours += s.hours;
    if (s.profit > 0) wins++;
    if (i == 0) {
      best = s.profit;
      worst = s.profit;
    } else {
      best = math.max(best, s.profit);
      worst = math.min(worst, s.profit);
    }
  }
  return SessionStats(
    totalProfit: cum,
    count: asc.length,
    hours: hours,
    hourly: hours > 0 ? cum / hours : 0,
    winRate: asc.isEmpty ? 0 : wins / asc.length,
    best: best,
    worst: worst,
    cumulative: cumulative,
    profits: profits,
    labels: labels,
  );
}

// ---------- chart ----------

class ResultsChart extends StatelessWidget {
  final SessionStats stats;
  final bool perSession;
  final String currency;

  const ResultsChart({
    super.key,
    required this.stats,
    required this.perSession,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.7,
      child: CustomPaint(
        painter: _ChartPainter(
          cumulative: stats.cumulative,
          profits: stats.profits,
          labels: stats.labels,
          currency: currency,
          perSession: perSession,
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<double> cumulative;
  final List<double> profits;
  final List<String> labels;
  final String currency;
  final bool perSession;

  _ChartPainter({
    required this.cumulative,
    required this.profits,
    required this.labels,
    required this.currency,
    required this.perSession,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 52.0;
    const padR = 10.0;
    const padT = 14.0;
    const padB = 26.0;
    final w = size.width - padL - padR;
    final h = size.height - padT - padB;
    if (w <= 0 || h <= 0) return;

    final values = perSession ? profits : cumulative;
    if (values.isEmpty) {
      _drawText(canvas, 'No sessions yet', size.width / 2, size.height / 2,
          const TextStyle(color: Colors.white54, fontSize: 14),
          centered: true);
      return;
    }

    double minV = values.reduce(math.min);
    double maxV = values.reduce(math.max);
    if (perSession) {
      minV = math.min(0, minV);
      maxV = math.max(0, maxV);
    }
    if ((maxV - minV).abs() < 1e-9) {
      maxV += 1;
      minV -= 1;
    }
    final pad = (maxV - minV) * 0.12;
    maxV += pad;
    minV -= pad;

    double xAt(int i) =>
        padL + (values.length == 1 ? w / 2 : w * i / (values.length - 1));
    double yAt(double v) => padT + h * (1 - (v - minV) / (maxV - minV));

    // gridlines + y labels
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1;
    const labelStyle = TextStyle(color: Colors.white54, fontSize: 10);
    for (int g = 0; g <= 4; g++) {
      final v = minV + (maxV - minV) * g / 4;
      final yy = yAt(v);
      canvas.drawLine(Offset(padL, yy), Offset(padL + w, yy), gridPaint);
      _drawText(canvas, shortMoney(v, currency), padL - 6, yy,
          labelStyle, rightAlign: true, centeredVertically: true);
    }

    // zero line
    if (minV < 0 && maxV > 0) {
      final zeroPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..strokeWidth = 1;
      canvas.drawLine(
          Offset(padL, yAt(0)), Offset(padL + w, yAt(0)), zeroPaint);
    }

    if (perSession) {
      final n = values.length;
      final slot = w / n;
      final barW = math.min(28.0, slot * 0.62);
      for (int i = 0; i < n; i++) {
        final v = values[i];
        final cx = padL + slot * i + slot / 2;
        final top = yAt(math.max(0, v));
        final bottom = yAt(math.min(0, v));
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTRB(cx - barW / 2, top, cx + barW / 2, bottom),
          const Radius.circular(2),
        );
        canvas.drawRRect(
          rect,
          Paint()
            ..color = v >= 0
                ? Colors.greenAccent.withValues(alpha: 0.85)
                : Colors.redAccent.withValues(alpha: 0.85),
        );
      }
    } else {
      final up = values.last >= 0;
      final lineColor = up ? Colors.greenAccent : Colors.redAccent;
      final path = Path();
      for (int i = 0; i < values.length; i++) {
        final pt = Offset(xAt(i), yAt(values[i]));
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      // area fill
      final area = Path.from(path)
        ..lineTo(xAt(values.length - 1), padT + h)
        ..lineTo(xAt(0), padT + h)
        ..close();
      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          lineColor.withValues(alpha: 0.35),
          lineColor.withValues(alpha: 0.02)
        ],
      );
      canvas.drawPath(
          area,
          Paint()
            ..shader = gradient
                .createShader(Rect.fromLTWH(padL, padT, w, h)));
      // line
      canvas.drawPath(
          path,
          Paint()
            ..color = lineColor
            ..strokeWidth = 2.5
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round);
      // dots
      final dotPaint = Paint()..color = lineColor;
      final n = values.length;
      final step = n > 40 ? (n / 40).ceil() : 1;
      for (int i = 0; i < n; i += step) {
        canvas.drawCircle(Offset(xAt(i), yAt(values[i])), 3, dotPaint);
      }
      canvas.drawCircle(
          Offset(xAt(n - 1), yAt(values.last)), 3.5, dotPaint);
    }

    // x labels: first / middle / last
    const xStyle = TextStyle(color: Colors.white38, fontSize: 9);
    if (labels.isNotEmpty) {
      _drawText(canvas, labels.first, xAt(0), padT + h + 6, xStyle);
      _drawText(canvas, labels.last, xAt(labels.length - 1), padT + h + 6,
          xStyle,
          rightAlign: true);
      if (labels.length > 4) {
        final mid = labels.length ~/ 2;
        _drawText(canvas, labels[mid], xAt(mid), padT + h + 6, xStyle,
            centered: true);
      }
    }
  }

  void _drawText(Canvas canvas, String text, double x, double y,
      TextStyle style,
      {bool rightAlign = false,
      bool centered = false,
      bool centeredVertically = false}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    double dx = x;
    if (rightAlign) dx = x - tp.width;
    if (centered) dx = x - tp.width / 2;
    double dy = y;
    if (centeredVertically) dy = y - tp.height / 2;
    if (centered && !rightAlign && !centeredVertically) dy = y;
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.cumulative != cumulative ||
      old.profits != profits ||
      old.perSession != perSession ||
      old.currency != currency;
}

// ---------- dashboard ----------

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String _filter = 'All';
  bool _perSession = false;

  @override
  Widget build(BuildContext context) {
    final filtered = _filter == 'All'
        ? store.sessions
        : store.sessions.where((s) => s.game == _filter).toList();
    final stats = computeStats(filtered);
    final currency = store.currency;
    final profitColor =
        stats.totalProfit >= 0 ? Colors.greenAccent : Colors.redAccent;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Total profit',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Colors.white70, letterSpacing: 0.4)),
        const SizedBox(height: 4),
        Text(
          formatMoney(stats.totalProfit, currency),
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: profitColor,
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          '${stats.count} sessions · ${formatHours(stats.hours)} hours · '
          '${formatMoney(stats.hourly, currency)}/hr',
          style: const TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 16),
        // filter chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: filterOptions.map((g) {
              final selected = _filter == g;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(g),
                  selected: selected,
                  onSelected: (_) => setState(() => _filter = g),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _perSession ? 'Profit per session' : 'Bankroll graph',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                              value: false, label: Text('Graph')),
                          ButtonSegment(
                              value: true, label: Text('Sessions')),
                        ],
                        selected: {_perSession},
                        onSelectionChanged: (sel) =>
                            setState(() => _perSession = sel.first),
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ResultsChart(
                    stats: stats,
                    perSession: _perSession,
                    currency: currency),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.9,
          children: [
            _StatCard(
                label: 'Sessions', value: '${stats.count}', icon: Icons.list),
            _StatCard(
                label: 'Hours played',
                value: formatHours(stats.hours),
                icon: Icons.schedule),
            _StatCard(
                label: 'Win rate',
                value: '${(stats.winRate * 100).toStringAsFixed(0)}%',
                icon: Icons.emoji_events),
            _StatCard(
                label: 'Hourly rate',
                value: formatMoney(stats.hourly, currency),
                icon: Icons.trending_up,
                valueColor: stats.hourly >= 0
                    ? Colors.greenAccent
                    : Colors.redAccent),
            _StatCard(
                label: 'Best session',
                value: stats.count == 0
                    ? '—'
                    : formatMoney(stats.best, currency),
                icon: Icons.arrow_circle_up,
                valueColor: Colors.greenAccent),
            _StatCard(
                label: 'Worst session',
                value: stats.count == 0
                    ? '—'
                    : formatMoney(stats.worst, currency),
                icon: Icons.arrow_circle_down,
                valueColor: Colors.redAccent),
          ],
        ),
        if (store.sessions.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text(
              'No sessions logged yet.\nTap + to add your first cash game.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? valueColor;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: Colors.white54),
                const SizedBox(width: 6),
                Text(label,
                    style: const TextStyle(
                        color: Colors.white60, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: valueColor ?? Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- sessions list ----------

class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sessions = store.sessions;
    if (sessions.isEmpty) {
      return const Center(
        child: Text(
          'No sessions yet.\nTap + to log a cash game.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sessions.length,
      itemBuilder: (context, i) {
        final s = sessions[i];
        final profitColor =
            s.profit >= 0 ? Colors.greenAccent : Colors.redAccent;
        return Dismissible(
          key: ValueKey(s.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: Colors.red.shade900,
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (_) async {
            return await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete session?'),
                    content: Text(
                        '${formatDate(s.date)} at ${s.location} — ${formatMoney(s.profit, store.currency)}'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Delete')),
                    ],
                  ),
                ) ??
                false;
          },
          onDismissed: (_) => store.removeSession(s.id),
          child: ListTile(
            title: Text(
                s.location.isEmpty ? '(No location)' : s.location,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              '${formatDate(s.date)} · ${s.game}${s.stakes.isNotEmpty ? ' · ${s.stakes}' : ''}'
              '${s.hours > 0 ? ' · ${formatHours(s.hours)}h' : ''}',
            ),
            trailing: Text(
              formatMoney(s.profit, store.currency),
              style: TextStyle(
                color: profitColor,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => SessionFormScreen(existing: s)),
            ),
          ),
        );
      },
    );
  }
}

// ---------- add / edit form ----------

class SessionFormScreen extends StatefulWidget {
  final PokerSession? existing;
  const SessionFormScreen({super.key, this.existing});

  @override
  State<SessionFormScreen> createState() => _SessionFormScreenState();
}

class _SessionFormScreenState extends State<SessionFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late DateTime _date;
  late String _game;
  final _locationCtrl = TextEditingController();
  final _stakesCtrl = TextEditingController();
  final _buyInCtrl = TextEditingController();
  final _cashOutCtrl = TextEditingController();
  final _hoursCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _date = e?.date ?? DateTime.now();
    _game = e?.game ?? 'PLO5';
    if (e != null) {
      _locationCtrl.text = e.location;
      _stakesCtrl.text = e.stakes;
      _buyInCtrl.text = e.buyIn.toStringAsFixed(0);
      _cashOutCtrl.text = e.cashOut.toStringAsFixed(0);
      _hoursCtrl.text = e.hours == 0 ? '' : e.hours.toString();
      _notesCtrl.text = e.notes;
    }
  }

  @override
  void dispose() {
    _locationCtrl.dispose();
    _stakesCtrl.dispose();
    _buyInCtrl.dispose();
    _cashOutCtrl.dispose();
    _hoursCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  double _parse(TextEditingController c) =>
      double.tryParse(c.text.replaceAll(',', '').trim()) ?? 0;

  double get _previewProfit => _parse(_cashOutCtrl) - _parse(_buyInCtrl);

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final s = PokerSession(
      id: widget.existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      date: _date,
      location: _locationCtrl.text.trim(),
      game: _game,
      stakes: _stakesCtrl.text.trim(),
      buyIn: _parse(_buyInCtrl),
      cashOut: _parse(_cashOutCtrl),
      hours: _parse(_hoursCtrl),
      notes: _notesCtrl.text.trim(),
    );
    if (widget.existing == null) {
      await store.addSession(s);
    } else {
      await store.updateSession(s);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final profit = _previewProfit;
    final profitColor = profit >= 0 ? Colors.greenAccent : Colors.redAccent;
    return Scaffold(
      appBar: AppBar(
        title:
            Text(widget.existing == null ? 'Add session' : 'Edit session'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today),
              title: Text(formatDate(_date)),
              subtitle: const Text('Session date'),
              trailing: const Icon(Icons.edit),
              onTap: _pickDate,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _locationCtrl,
              decoration: const InputDecoration(
                labelText: 'Location / poker room',
                hintText: 'e.g. Wild Aces, Royce Clark',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _game,
              decoration: const InputDecoration(
                labelText: 'Game',
                border: OutlineInputBorder(),
              ),
              items: gameTypes
                  .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                  .toList(),
              onChanged: (v) => setState(() => _game = v ?? _game),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _stakesCtrl,
              decoration: const InputDecoration(
                labelText: 'Stakes',
                hintText: 'e.g. 25/50, 50/100',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.text,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _buyInCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Total buy-in',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty)
                            ? 'Enter buy-in'
                            : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _cashOutCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Cash-out',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty)
                            ? 'Enter cash-out'
                            : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _hoursCtrl,
              decoration: const InputDecoration(
                labelText: 'Hours played',
                hintText: 'e.g. 4.5',
                border: OutlineInputBorder(),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notesCtrl,
              decoration: const InputDecoration(
                labelText: 'Notes',
                hintText: 'Table conditions, key hands, tilt notes…',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Session result',
                        style: TextStyle(fontSize: 16)),
                    Text(
                      formatMoney(profit, store.currency),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: profitColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check),
              label: const Text('Save session'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- settings ----------

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  String _csvEscape(String v) => '"${v.replaceAll('"', '""')}"';

  String _buildCsv() {
    final sb = StringBuffer(
        'date,location,game,stakes,buy_in,cash_out,profit,hours,notes\n');
    final asc = List<PokerSession>.from(store.sessions)
      ..sort((a, b) => a.date.compareTo(b.date));
    for (final s in asc) {
      sb.writeln([
        s.date.toIso8601String(),
        _csvEscape(s.location),
        s.game,
        _csvEscape(s.stakes),
        s.buyIn.toStringAsFixed(0),
        s.cashOut.toStringAsFixed(0),
        s.profit.toStringAsFixed(0),
        s.hours.toString(),
        _csvEscape(s.notes),
      ].join(','));
    }
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final currencyCtrl = TextEditingController(text: store.currency);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Currency symbol',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: currencyCtrl,
                decoration: const InputDecoration(
                  hintText: '₱, \$, €…',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () async {
                await store.setCurrency(currencyCtrl.text);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Currency saved')));
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text('Data', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.file_download),
          title: const Text('Export sessions as CSV'),
          subtitle: const Text('Copies all sessions to the clipboard'),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: _buildCsv()));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text(
                      'CSV copied — paste it into a spreadsheet')));
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
          title: const Text('Delete all sessions',
              style: TextStyle(color: Colors.redAccent)),
          onTap: () async {
            final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete everything?'),
                    content: const Text(
                        'All logged sessions will be permanently removed.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Delete all')),
                    ],
                  ),
                ) ??
                false;
            if (ok) await store.clearAll();
          },
        ),
        const SizedBox(height: 24),
        const Text(
          'Poker Results v1.0 — data is stored only on this phone. '
          'Export CSV regularly to keep a backup.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }
}

// ---------- root ----------

class PokerResultsApp extends StatelessWidget {
  const PokerResultsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Poker Results',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const RootScreen(),
    );
  }
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    store.load();
  }

  void _openForm() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SessionFormScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.loaded) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final titles = ['Poker Results', 'Sessions', 'Settings'];
        return Scaffold(
          appBar: AppBar(title: Text(titles[_tab])),
          body: IndexedStack(
            index: _tab,
            children: const [
              DashboardScreen(),
              SessionsScreen(),
              SettingsScreen(),
            ],
          ),
          floatingActionButton: _tab == 2
              ? null
              : FloatingActionButton(
                  onPressed: _openForm,
                  tooltip: 'Add session',
                  child: const Icon(Icons.add),
                ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _tab,
            onTap: (i) => setState(() => _tab = i),
            items: const [
              BottomNavigationBarItem(
                  icon: Icon(Icons.show_chart), label: 'Dashboard'),
              BottomNavigationBarItem(
                  icon: Icon(Icons.list), label: 'Sessions'),
              BottomNavigationBarItem(
                  icon: Icon(Icons.settings), label: 'Settings'),
            ],
          ),
        );
      },
    );
  }
}
