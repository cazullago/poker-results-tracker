import 'dart:async';
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

/// "3h 32m 05s" style live clock.
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (h > 0) return '${h}h ${m}m ${s}s';
  return '${m}m ${s}s';
}

/// Big blind parsed from a stakes string like "25/50" -> 50.
double? bigBlindOf(String stakes) {
  final parts = stakes.split('/');
  if (parts.isEmpty) return null;
  return double.tryParse(parts.last.trim().replaceAll(',', ''));
}

// ---------- data models ----------

class PokerSession {
  final String id;
  final DateTime date;
  final String location;
  final String game;
  final String stakes;
  final double buyIn;
  final double cashOut;
  final double hours;
  final double expenses;
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
    this.expenses = 0,
    required this.notes,
  });

  double get grossProfit => cashOut - buyIn;

  /// Net result after expenses (food, tips, transport).
  double get profit => grossProfit - expenses;

  /// Profit expressed in big blinds, when stakes are parseable.
  double? get profitInBB {
    final bb = bigBlindOf(stakes);
    if (bb == null || bb == 0) return null;
    return profit / bb;
  }

  double? get bbPerHour {
    final pbb = profitInBB;
    if (pbb == null || hours <= 0) return null;
    return pbb / hours;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'location': location,
        'game': game,
        'stakes': stakes,
        'buyIn': buyIn,
        'cashOut': cashOut,
        'hours': hours,
        'expenses': expenses,
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
        expenses: (j['expenses'] as num?)?.toDouble() ?? 0,
        notes: j['notes'] as String? ?? '',
      );
}

class LiveSession {
  final String id;
  final DateTime startTime;
  final String location;
  final String game;
  final String stakes;
  double buyIn; // total, including rebuys
  double currentStack;
  int rebuys;
  double breakSeconds; // completed break time
  DateTime? breakStart; // non-null while on a break

  LiveSession({
    required this.id,
    required this.startTime,
    required this.location,
    required this.game,
    required this.stakes,
    required this.buyIn,
    required this.currentStack,
    this.rebuys = 0,
    this.breakSeconds = 0,
    this.breakStart,
  });

  bool get onBreak => breakStart != null;

  /// Playing time (breaks excluded) at [now].
  Duration elapsed(DateTime now) {
    var secs = now.difference(startTime).inSeconds - breakSeconds.round();
    if (breakStart != null) {
      secs -= now.difference(breakStart!).inSeconds;
    }
    if (secs < 0) secs = 0;
    return Duration(seconds: secs);
  }

  Duration totalBreak(DateTime now) {
    var secs = breakSeconds;
    if (breakStart != null) {
      secs += now.difference(breakStart!).inSeconds;
    }
    if (secs < 0) secs = 0;
    return Duration(seconds: secs.round());
  }

  double get liveProfit => currentStack - buyIn;

  Map<String, dynamic> toJson() => {
        'id': id,
        'startTime': startTime.toIso8601String(),
        'location': location,
        'game': game,
        'stakes': stakes,
        'buyIn': buyIn,
        'currentStack': currentStack,
        'rebuys': rebuys,
        'breakSeconds': breakSeconds,
        'breakStart': breakStart?.toIso8601String(),
      };

  factory LiveSession.fromJson(Map<String, dynamic> j) => LiveSession(
        id: j['id'] as String,
        startTime: DateTime.parse(j['startTime'] as String),
        location: j['location'] as String? ?? '',
        game: j['game'] as String? ?? 'PLO5',
        stakes: j['stakes'] as String? ?? '',
        buyIn: (j['buyIn'] as num).toDouble(),
        currentStack: (j['currentStack'] as num).toDouble(),
        rebuys: (j['rebuys'] as num?)?.toInt() ?? 0,
        breakSeconds: (j['breakSeconds'] as num?)?.toDouble() ?? 0,
        breakStart: j['breakStart'] == null
            ? null
            : DateTime.parse(j['breakStart'] as String),
      );
}

class BankrollTxn {
  final String id;
  final DateTime date;
  final double amount; // + deposit, - withdrawal
  final String note;

  BankrollTxn({
    required this.id,
    required this.date,
    required this.amount,
    required this.note,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'amount': amount,
        'note': note,
      };

  factory BankrollTxn.fromJson(Map<String, dynamic> j) => BankrollTxn(
        id: j['id'] as String,
        date: DateTime.parse(j['date'] as String),
        amount: (j['amount'] as num).toDouble(),
        note: j['note'] as String? ?? '',
      );
}

// ---------- store ----------

class SessionStore extends ChangeNotifier {
  List<PokerSession> sessions = [];
  List<BankrollTxn> bankrollTxns = [];
  LiveSession? live;
  String currency = '₱';
  double bankrollStart = 0;
  double monthlyGoal = 0;
  bool loaded = false;

  double get totalProfitAll =>
      sessions.fold(0.0, (sum, s) => sum + s.profit);

  double get currentBankroll =>
      bankrollStart +
      totalProfitAll +
      bankrollTxns.fold(0.0, (sum, t) => sum + t.amount);

  bool get bankrollConfigured =>
      bankrollStart != 0 || bankrollTxns.isNotEmpty;

  double get thisMonthProfit {
    final now = DateTime.now();
    return sessions
        .where((s) => s.date.year == now.year && s.date.month == now.month)
        .fold(0.0, (sum, s) => sum + s.profit);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    currency = prefs.getString('currency') ?? '₱';
    bankrollStart = prefs.getDouble('bankroll_start') ?? 0;
    monthlyGoal = prefs.getDouble('monthly_goal') ?? 0;
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
    final rawTxns = prefs.getString('bankroll_txns');
    if (rawTxns != null && rawTxns.isNotEmpty) {
      try {
        final list = jsonDecode(rawTxns) as List<dynamic>;
        bankrollTxns = list
            .map((e) => BankrollTxn.fromJson(e as Map<String, dynamic>))
            .toList();
        bankrollTxns.sort((a, b) => b.date.compareTo(a.date));
      } catch (_) {
        bankrollTxns = [];
      }
    }
    final rawLive = prefs.getString('live_session');
    if (rawLive != null && rawLive.isNotEmpty) {
      try {
        live = LiveSession.fromJson(
            jsonDecode(rawLive) as Map<String, dynamic>);
      } catch (_) {
        live = null;
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currency', currency);
    await prefs.setDouble('bankroll_start', bankrollStart);
    await prefs.setDouble('monthly_goal', monthlyGoal);
    await prefs.setString(
        'sessions', jsonEncode(sessions.map((s) => s.toJson()).toList()));
    await prefs.setString('bankroll_txns',
        jsonEncode(bankrollTxns.map((t) => t.toJson()).toList()));
    if (live == null) {
      await prefs.remove('live_session');
    } else {
      await prefs.setString('live_session', jsonEncode(live!.toJson()));
    }
  }

  // sessions

  Future<void> addSession(PokerSession s) async {
    sessions.add(s);
    sessions.sort((a, b) => b.date.compareTo(a.date));
    notifyListeners();
    await _persist();
  }

  Future<void> addSessions(List<PokerSession> list) async {
    sessions.addAll(list);
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

  Future<void> clearAllSessions() async {
    sessions = [];
    notifyListeners();
    await _persist();
  }

  // settings

  Future<void> setCurrency(String c) async {
    currency = c.trim().isEmpty ? '₱' : c.trim();
    notifyListeners();
    await _persist();
  }

  Future<void> setBankrollStart(double v) async {
    bankrollStart = v;
    notifyListeners();
    await _persist();
  }

  Future<void> setMonthlyGoal(double v) async {
    monthlyGoal = v;
    notifyListeners();
    await _persist();
  }

  Future<void> addBankrollTxn(BankrollTxn t) async {
    bankrollTxns.add(t);
    bankrollTxns.sort((a, b) => b.date.compareTo(a.date));
    notifyListeners();
    await _persist();
  }

  Future<void> removeBankrollTxn(String id) async {
    bankrollTxns.removeWhere((t) => t.id == id);
    notifyListeners();
    await _persist();
  }

  // live session

  Future<void> startLive({
    required String location,
    required String game,
    required String stakes,
    required double buyIn,
  }) async {
    live = LiveSession(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      startTime: DateTime.now(),
      location: location,
      game: game,
      stakes: stakes,
      buyIn: buyIn,
      currentStack: buyIn,
    );
    notifyListeners();
    await _persist();
  }

  Future<void> updateLiveStack(double stack) async {
    if (live == null) return;
    live!.currentStack = stack;
    notifyListeners();
    await _persist();
  }

  Future<void> addLiveRebuy(double amount) async {
    if (live == null || amount <= 0) return;
    live!.buyIn += amount;
    live!.currentStack += amount;
    live!.rebuys += 1;
    notifyListeners();
    await _persist();
  }

  Future<void> toggleLiveBreak() async {
    if (live == null) return;
    final now = DateTime.now();
    if (live!.breakStart == null) {
      live!.breakStart = now;
    } else {
      live!.breakSeconds +=
          now.difference(live!.breakStart!).inSeconds.toDouble();
      live!.breakStart = null;
    }
    notifyListeners();
    await _persist();
  }

  Future<void> discardLive() async {
    live = null;
    notifyListeners();
    await _persist();
  }

  /// Ends the live session and saves it as a completed session.
  Future<PokerSession?> finishLive({
    required double cashOut,
    double expenses = 0,
    String notes = '',
  }) async {
    final l = live;
    if (l == null) return null;
    final now = DateTime.now();
    final hours = (l.elapsed(now).inSeconds / 3600 * 100).round() / 100;
    final s = PokerSession(
      id: l.id,
      date: l.startTime,
      location: l.location,
      game: l.game,
      stakes: l.stakes,
      buyIn: l.buyIn,
      cashOut: cashOut,
      hours: hours,
      expenses: expenses,
      notes: notes,
    );
    live = null;
    sessions.add(s);
    sessions.sort((a, b) => b.date.compareTo(a.date));
    notifyListeners();
    await _persist();
    return s;
  }

  // backup / restore

  String exportJson() {
    return const JsonEncoder.withIndent('  ').convert({
      'app': 'poker_results',
      'version': 2,
      'currency': currency,
      'bankrollStart': bankrollStart,
      'monthlyGoal': monthlyGoal,
      'sessions': sessions.map((s) => s.toJson()).toList(),
      'bankrollTxns': bankrollTxns.map((t) => t.toJson()).toList(),
    });
  }

  /// Returns number of sessions imported, or -1 on bad data.
  Future<int> importJson(String text) async {
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      final list = data['sessions'] as List<dynamic>;
      final imported = list
          .map((e) => PokerSession.fromJson(e as Map<String, dynamic>))
          .toList();
      sessions = imported;
      sessions.sort((a, b) => b.date.compareTo(a.date));
      if (data['currency'] is String) currency = data['currency'] as String;
      if (data['bankrollStart'] is num) {
        bankrollStart = (data['bankrollStart'] as num).toDouble();
      }
      if (data['monthlyGoal'] is num) {
        monthlyGoal = (data['monthlyGoal'] as num).toDouble();
      }
      final txns = data['bankrollTxns'];
      if (txns is List) {
        bankrollTxns = txns
            .map((e) => BankrollTxn.fromJson(e as Map<String, dynamic>))
            .toList();
        bankrollTxns.sort((a, b) => b.date.compareTo(a.date));
      }
      notifyListeners();
      await _persist();
      return imported.length;
    } catch (_) {
      return -1;
    }
  }
}

final SessionStore store = SessionStore();

// ---------- CSV import ----------

/// Splits one CSV line, honoring double-quoted fields and "" escapes.
List<String> parseCsvLine(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (int i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buf.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  out.add(buf.toString());
  return out;
}

/// Parses sessions from CSV text in the app's export format (columns are
/// matched by header name; `expenses` and other columns may be missing).
/// Rows that don't parse are skipped.
List<PokerSession> parseCsvSessions(String text) {
  final lines =
      text.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.length < 2) return [];
  final header =
      parseCsvLine(lines.first).map((h) => h.trim().toLowerCase()).toList();
  int idx(String name) => header.indexOf(name);
  final iDate = idx('date');
  final iLoc = idx('location');
  final iGame = idx('game');
  final iStakes = idx('stakes');
  final iBuy = idx('buy_in');
  final iCash = idx('cash_out');
  final iExp = idx('expenses');
  final iHours = idx('hours');
  final iNotes = idx('notes');
  if (iDate < 0 || iBuy < 0 || iCash < 0) return [];
  final out = <PokerSession>[];
  for (final line in lines.skip(1)) {
    final cols = parseCsvLine(line);
    String get(int i) => (i >= 0 && i < cols.length) ? cols[i].trim() : '';
    final date = DateTime.tryParse(get(iDate));
    final buy = double.tryParse(get(iBuy));
    final cash = double.tryParse(get(iCash));
    if (date == null || buy == null || cash == null) continue;
    out.add(PokerSession(
      id: 'csv-${date.microsecondsSinceEpoch}-${out.length}',
      date: date,
      location: get(iLoc),
      game: get(iGame).isEmpty ? 'NLHE' : get(iGame),
      stakes: get(iStakes),
      buyIn: buy,
      cashOut: cash,
      hours: double.tryParse(get(iHours)) ?? 0,
      expenses: double.tryParse(get(iExp)) ?? 0,
      notes: get(iNotes),
    ));
  }
  return out;
}

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

class BreakdownRow {
  final String name;
  final int count;
  final double hours;
  final double profit;
  BreakdownRow(this.name, this.count, this.hours, this.profit);
  double get hourly => hours > 0 ? profit / hours : 0;
}

List<BreakdownRow> breakdownBy(
    List<PokerSession> sessions, String Function(PokerSession) keyOf) {
  final map = <String, List<PokerSession>>{};
  for (final s in sessions) {
    final k = keyOf(s);
    map.putIfAbsent(k, () => []).add(s);
  }
  final rows = map.entries.map((e) {
    final list = e.value;
    return BreakdownRow(
      e.key,
      list.length,
      list.fold(0.0, (a, s) => a + s.hours),
      list.fold(0.0, (a, s) => a + s.profit),
    );
  }).toList();
  rows.sort((a, b) => b.profit.compareTo(a.profit));
  return rows;
}

const List<String> weekdayNames = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
];

List<BreakdownRow> breakdownByWeekday(List<PokerSession> sessions) {
  final rows = breakdownBy(sessions, (s) => weekdayNames[s.date.weekday - 1]);
  rows.sort((a, b) => weekdayNames
      .indexOf(a.name)
      .compareTo(weekdayNames.indexOf(b.name)));
  return rows;
}

class MonthBucket {
  final String label;
  final double profit;
  MonthBucket(this.label, this.profit);
}

List<MonthBucket> monthlyBuckets(List<PokerSession> sessions) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final map = <String, double>{};
  final keys = <String>[];
  final asc = List<PokerSession>.from(sessions)
    ..sort((a, b) => a.date.compareTo(b.date));
  for (final s in asc) {
    final key = '${s.date.year}-${s.date.month.toString().padLeft(2, '0')}';
    if (!map.containsKey(key)) keys.add(key);
    map[key] = (map[key] ?? 0) + s.profit;
  }
  return keys.map((k) {
    final parts = k.split('-');
    final label = "${months[int.parse(parts[1]) - 1]} '${parts[0].substring(2)}";
    return MonthBucket(label, map[k]!);
  }).toList();
}

/// Current streak from the most recent session: e.g. ("W", 3) = won last 3.
(String, int) currentStreak(List<PokerSession> sessionsDesc) {
  if (sessionsDesc.isEmpty) return ('—', 0);
  final first = sessionsDesc.first.profit;
  final kind = first > 0 ? 'W' : (first < 0 ? 'L' : '—');
  if (kind == '—') return ('—', 0);
  var n = 0;
  for (final s in sessionsDesc) {
    final k = s.profit > 0 ? 'W' : (s.profit < 0 ? 'L' : '—');
    if (k == kind) {
      n++;
    } else {
      break;
    }
  }
  return (kind, n);
}

int longestWinStreak(List<PokerSession> sessions) {
  final asc = List<PokerSession>.from(sessions)
    ..sort((a, b) => a.date.compareTo(b.date));
  var best = 0;
  var run = 0;
  for (final s in asc) {
    if (s.profit > 0) {
      run++;
      best = math.max(best, run);
    } else {
      run = 0;
    }
  }
  return best;
}

// ---------- chart ----------

class ResultsChart extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final bool bars;
  final String currency;

  const ResultsChart({
    super.key,
    required this.values,
    required this.labels,
    required this.bars,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.7,
      child: CustomPaint(
        painter: _ChartPainter(
          values: values,
          labels: labels,
          bars: bars,
          currency: currency,
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final bool bars;
  final String currency;

  _ChartPainter({
    required this.values,
    required this.labels,
    required this.bars,
    required this.currency,
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

    if (values.isEmpty) {
      _drawText(canvas, 'No sessions yet', size.width / 2, size.height / 2,
          const TextStyle(color: Colors.white54, fontSize: 14),
          centered: true, centeredVertically: true);
      return;
    }

    double minV = values.reduce(math.min);
    double maxV = values.reduce(math.max);
    if (bars) {
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
      _drawText(canvas, shortMoney(v, currency), padL - 6, yy, labelStyle,
          rightAlign: true, centeredVertically: true);
    }

    // zero line
    if (minV < 0 && maxV > 0) {
      final zeroPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..strokeWidth = 1;
      canvas.drawLine(
          Offset(padL, yAt(0)), Offset(padL + w, yAt(0)), zeroPaint);
    }

    if (bars) {
      final n = values.length;
      final slot = w / n;
      final barW = math.min(30.0, slot * 0.62);
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
      final lineColor =
          values.last >= values.first ? Colors.greenAccent : Colors.redAccent;
      final path = Path();
      for (int i = 0; i < values.length; i++) {
        final pt = Offset(xAt(i), yAt(values[i]));
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
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
            ..shader =
                gradient.createShader(Rect.fromLTWH(padL, padT, w, h)));
      canvas.drawPath(
          path,
          Paint()
            ..color = lineColor
            ..strokeWidth = 2.5
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round);
      final dotPaint = Paint()..color = lineColor;
      final n = values.length;
      final step = n > 40 ? (n / 40).ceil() : 1;
      for (int i = 0; i < n; i += step) {
        canvas.drawCircle(Offset(xAt(i), yAt(values[i])), 3, dotPaint);
      }
      canvas.drawCircle(Offset(xAt(n - 1), yAt(values.last)), 3.5, dotPaint);
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
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.values != values || old.bars != bars || old.currency != currency;
}

// ---------- dashboard ----------

enum ChartMode { bankroll, sessions, monthly }

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String _filter = 'All';
  ChartMode _mode = ChartMode.bankroll;

  @override
  Widget build(BuildContext context) {
    final filtered = _filter == 'All'
        ? store.sessions
        : store.sessions.where((s) => s.game == _filter).toList();
    final stats = computeStats(filtered);
    final currency = store.currency;
    final profitColor =
        stats.totalProfit >= 0 ? Colors.greenAccent : Colors.redAccent;

    // chart data per mode
    late final List<double> chartValues;
    late final List<String> chartLabels;
    late final bool chartBars;
    late final String chartTitle;
    switch (_mode) {
      case ChartMode.bankroll:
        chartValues = [0, ...stats.cumulative];
        chartLabels = ['Start', ...stats.labels];
        chartBars = false;
        chartTitle = 'Bankroll graph';
        break;
      case ChartMode.sessions:
        chartValues = stats.profits;
        chartLabels = stats.labels;
        chartBars = true;
        chartTitle = 'Profit per session';
        break;
      case ChartMode.monthly:
        final buckets = monthlyBuckets(filtered);
        chartValues = buckets.map((b) => b.profit).toList();
        chartLabels = buckets.map((b) => b.label).toList();
        chartBars = true;
        chartTitle = 'Profit per month';
        break;
    }

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
        if (store.bankrollConfigured) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.account_balance_wallet,
                  size: 16, color: Colors.amberAccent),
              const SizedBox(width: 6),
              Text(
                'Bankroll ${formatMoney(store.currentBankroll, currency)}',
                style: const TextStyle(
                    color: Colors.amberAccent,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
        if (store.monthlyGoal > 0) ...[
          const SizedBox(height: 12),
          _GoalProgress(),
        ],
        const SizedBox(height: 16),
        if (store.live != null)
          _LiveBanner(live: store.live!)
        else
          FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LiveSetupScreen()),
            ),
            icon: const Icon(Icons.play_circle_fill),
            label: const Text('Start live session'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green.shade700,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        const SizedBox(height: 16),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(chartTitle,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      SegmentedButton<ChartMode>(
                        segments: const [
                          ButtonSegment(
                              value: ChartMode.bankroll,
                              label: Text('Graph')),
                          ButtonSegment(
                              value: ChartMode.sessions,
                              label: Text('Sessions')),
                          ButtonSegment(
                              value: ChartMode.monthly,
                              label: Text('Monthly')),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (sel) =>
                            setState(() => _mode = sel.first),
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
                  values: chartValues,
                  labels: chartLabels,
                  bars: chartBars,
                  currency: currency,
                ),
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
                value:
                    stats.count == 0 ? '—' : formatMoney(stats.best, currency),
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
              'No sessions logged yet.\nStart a live session or tap + to add one.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ),
      ],
    );
  }
}

class _GoalProgress extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final goal = store.monthlyGoal;
    final profit = store.thisMonthProfit;
    final pct = goal > 0 ? (profit / goal).clamp(0.0, 1.0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Monthly goal',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            Text(
              '${formatMoney(profit, store.currency)} / ${formatMoney(goal, store.currency)}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 10,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation<Color>(
                profit >= 0 ? Colors.greenAccent : Colors.redAccent),
          ),
        ),
      ],
    );
  }
}

class _LiveBanner extends StatefulWidget {
  final LiveSession live;
  const _LiveBanner({required this.live});

  @override
  State<_LiveBanner> createState() => _LiveBannerState();
}

class _LiveBannerState extends State<_LiveBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.live;
    final elapsed = live.elapsed(DateTime.now());
    final profit = live.liveProfit;
    return Card(
      color: Colors.green.shade900,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const LiveSessionScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.fiber_manual_record,
                  color: Colors.redAccent, size: 16),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LIVE · ${live.game}${live.stakes.isNotEmpty ? ' ${live.stakes}' : ''}'
                      '${live.location.isNotEmpty ? ' · ${live.location}' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatDuration(elapsed)} played'
                      '${live.onBreak ? ' · on break' : ''}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              Text(
                formatMoney(profit, store.currency),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: profit >= 0
                      ? Colors.greenAccent
                      : Colors.redAccent,
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white54),
            ],
          ),
        ),
      ),
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

// ---------- stats ----------

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sessions = store.sessions;
    if (sessions.isEmpty) {
      return const Center(
        child: Text(
          'No sessions yet — stats will appear here\nonce you log some games.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    final currency = store.currency;
    final (streakKind, streakCount) = currentStreak(sessions);
    final byGame = breakdownBy(sessions, (s) => s.game);
    final byLocation = breakdownBy(
        sessions, (s) => s.location.isEmpty ? '(No location)' : s.location);
    final byWeekday = breakdownByWeekday(sessions);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StreakStat(
                  label: 'Current streak',
                  value: streakCount == 0
                      ? '—'
                      : '$streakKind$streakCount',
                  color: streakKind == 'W'
                      ? Colors.greenAccent
                      : (streakKind == 'L'
                          ? Colors.redAccent
                          : Colors.white),
                ),
                _StreakStat(
                  label: 'Longest win streak',
                  value: '${longestWinStreak(sessions)}',
                  color: Colors.greenAccent,
                ),
                _StreakStat(
                  label: 'Total sessions',
                  value: '${sessions.length}',
                  color: Colors.white,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _BreakdownSection(
            title: 'By game', rows: byGame, currency: currency),
        const SizedBox(height: 16),
        _BreakdownSection(
            title: 'By location', rows: byLocation, currency: currency),
        const SizedBox(height: 16),
        _BreakdownSection(
            title: 'By day of week', rows: byWeekday, currency: currency),
        const SizedBox(height: 8),
        const Text(
          'Find your most profitable game, room and day — '
          'then play more of those.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _StreakStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StreakStat(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 24, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ],
    );
  }
}

class _BreakdownSection extends StatelessWidget {
  final String title;
  final List<BreakdownRow> rows;
  final String currency;
  const _BreakdownSection(
      {required this.title, required this.rows, required this.currency});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(title,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            ...rows.map((r) => ListTile(
                  dense: true,
                  title: Text(r.name),
                  subtitle: Text(
                      '${r.count} sessions · ${formatHours(r.hours)}h · '
                      '${formatMoney(r.hourly, currency)}/hr'),
                  trailing: Text(
                    formatMoney(r.profit, currency),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: r.profit >= 0
                          ? Colors.greenAccent
                          : Colors.redAccent,
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

// ---------- sessions list ----------

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  final _searchCtrl = TextEditingController();
  String _gameFilter = 'All';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _searchCtrl.text.trim().toLowerCase();
    final sessions = store.sessions.where((s) {
      if (_gameFilter != 'All' && s.game != _gameFilter) return false;
      if (q.isEmpty) return true;
      return s.location.toLowerCase().contains(q) ||
          s.stakes.toLowerCase().contains(q) ||
          s.notes.toLowerCase().contains(q);
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search room, stakes, notes…',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: filterOptions.map((g) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(g),
                  selected: _gameFilter == g,
                  onSelected: (_) => setState(() => _gameFilter = g),
                ),
              );
            }).toList(),
          ),
        ),
        Expanded(
          child: sessions.isEmpty
              ? const Center(
                  child: Text(
                    'No sessions match.',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              : ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (context, i) {
                    final s = sessions[i];
                    final profitColor = s.profit >= 0
                        ? Colors.greenAccent
                        : Colors.redAccent;
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
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('Cancel')),
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, true),
                                      child: const Text('Delete')),
                                ],
                              ),
                            ) ??
                            false;
                      },
                      onDismissed: (_) => store.removeSession(s.id),
                      child: ListTile(
                        title: Text(
                            s.location.isEmpty
                                ? '(No location)'
                                : s.location,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
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
                              builder: (_) =>
                                  SessionDetailScreen(session: s)),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ---------- session detail ----------

class SessionDetailScreen extends StatelessWidget {
  final PokerSession session;
  const SessionDetailScreen({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final s = session;
    final currency = store.currency;
    final profitColor =
        s.profit >= 0 ? Colors.greenAccent : Colors.redAccent;
    final sessionHourly = s.hours > 0 ? s.profit / s.hours : null;

    Widget row(String label, String value, {Color? color}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white60)),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session detail'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Edit',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => SessionFormScreen(existing: s)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete',
            onPressed: () async {
              final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Delete session?'),
                      content: Text(
                          '${formatDate(s.date)} at ${s.location} — ${formatMoney(s.profit, currency)}'),
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
              if (ok) {
                await store.removeSession(s.id);
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                Text(
                  formatMoney(s.profit, currency),
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    color: profitColor,
                  ),
                ),
                Text(
                  '${s.game}${s.stakes.isNotEmpty ? ' · ${s.stakes}' : ''} · ${formatDate(s.date)}',
                  style: const TextStyle(color: Colors.white60),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  row('Location',
                      s.location.isEmpty ? '—' : s.location),
                  row('Buy-in', formatMoney(s.buyIn, currency)),
                  row('Cash-out', formatMoney(s.cashOut, currency)),
                  if (s.expenses > 0)
                    row('Expenses', '-${formatMoney(s.expenses, currency)}'),
                  const Divider(),
                  row('Net result', formatMoney(s.profit, currency),
                      color: profitColor),
                  row('Hours played', formatHours(s.hours)),
                  if (sessionHourly != null)
                    row('Hourly rate',
                        formatMoney(sessionHourly, currency)),
                  if (s.profitInBB != null)
                    row('Result in BB',
                        '${s.profitInBB!.toStringAsFixed(1)} BB'),
                  if (s.bbPerHour != null)
                    row('BB / hour',
                        '${s.bbPerHour!.toStringAsFixed(1)} BB/hr'),
                ],
              ),
            ),
          ),
          if (s.notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Notes',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(s.notes),
          ],
        ],
      ),
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
  final _expensesCtrl = TextEditingController();
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
      _expensesCtrl.text =
          e.expenses == 0 ? '' : e.expenses.toStringAsFixed(0);
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
    _expensesCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  double _parse(TextEditingController c) =>
      double.tryParse(c.text.replaceAll(',', '').trim()) ?? 0;

  double get _previewProfit =>
      _parse(_cashOutCtrl) - _parse(_buyInCtrl) - _parse(_expensesCtrl);

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
      expenses: _parse(_expensesCtrl),
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
                    validator: (v) => (v == null || v.trim().isEmpty)
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
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Enter cash-out'
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _hoursCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Hours played',
                      hintText: 'e.g. 4.5',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _expensesCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Expenses (optional)',
                      hintText: 'Food, tips, transport',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
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
                    const Text('Net result', style: TextStyle(fontSize: 16)),
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

// ---------- live session setup ----------

class LiveSetupScreen extends StatefulWidget {
  const LiveSetupScreen({super.key});

  @override
  State<LiveSetupScreen> createState() => _LiveSetupScreenState();
}

class _LiveSetupScreenState extends State<LiveSetupScreen> {
  String _game = 'PLO5';
  final _locationCtrl = TextEditingController();
  final _stakesCtrl = TextEditingController();
  final _buyInCtrl = TextEditingController();

  @override
  void dispose() {
    _locationCtrl.dispose();
    _stakesCtrl.dispose();
    _buyInCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final buyIn =
        double.tryParse(_buyInCtrl.text.replaceAll(',', '').trim()) ?? 0;
    if (buyIn <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter your buy-in to start')));
      return;
    }
    await store.startLive(
      location: _locationCtrl.text.trim(),
      game: _game,
      stakes: _stakesCtrl.text.trim(),
      buyIn: buyIn,
    );
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LiveSessionScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Start live session')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Set up your session, then hit start — the clock runs '
            'until you end it, even if you close the app.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          TextField(
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
          TextField(
            controller: _stakesCtrl,
            decoration: const InputDecoration(
              labelText: 'Stakes',
              hintText: 'e.g. 25/50, 50/100',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _buyInCtrl,
            decoration: const InputDecoration(
              labelText: 'Buy-in',
              border: OutlineInputBorder(),
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start the clock'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green.shade700,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- live session ----------

class LiveSessionScreen extends StatefulWidget {
  const LiveSessionScreen({super.key});

  @override
  State<LiveSessionScreen> createState() => _LiveSessionScreenState();
}

class _LiveSessionScreenState extends State<LiveSessionScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<double?> _amountDialog({
    required String title,
    required String label,
    double initial = 0,
  }) async {
    final ctrl = TextEditingController(
        text: initial == 0 ? '' : initial.toStringAsFixed(0));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(
                ctx,
                double.tryParse(
                    ctrl.text.replaceAll(',', '').trim())),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<void> _endSession(LiveSession live) async {
    final cashOutCtrl = TextEditingController(
        text: live.currentStack.toStringAsFixed(0));
    final expensesCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End session?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: cashOutCtrl,
              decoration: const InputDecoration(
                labelText: 'Final cash-out',
                border: OutlineInputBorder(),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: expensesCtrl,
              decoration: const InputDecoration(
                labelText: 'Expenses (optional)',
                hintText: 'Food, tips, transport',
                border: OutlineInputBorder(),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notesCtrl,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep playing')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('End & save')),
        ],
      ),
    );
    if (confirmed == true) {
      final cashOut =
          double.tryParse(cashOutCtrl.text.replaceAll(',', '').trim()) ??
              live.currentStack;
      final expenses =
          double.tryParse(expensesCtrl.text.replaceAll(',', '').trim()) ??
              0;
      await store.finishLive(
        cashOut: cashOut,
        expenses: expenses,
        notes: notesCtrl.text.trim(),
      );
      if (mounted) {
        Navigator.popUntil(context, (r) => r.isFirst);
      }
    }
    cashOutCtrl.dispose();
    expensesCtrl.dispose();
    notesCtrl.dispose();
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Discard live session?'),
            content: const Text(
                'This session will not be saved to your results.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Keep it')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Discard')),
            ],
          ),
        ) ??
        false;
    if (ok) {
      await store.discardLive();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = store.live;
    if (live == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Live session')),
        body: const Center(
          child: Text('No live session running.',
              style: TextStyle(color: Colors.white54)),
        ),
      );
    }
    final now = DateTime.now();
    final elapsed = live.elapsed(now);
    final breakTime = live.totalBreak(now);
    final profit = live.liveProfit;
    final profitColor = profit >= 0 ? Colors.greenAccent : Colors.redAccent;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live session'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Discard session',
            onPressed: _discard,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.fiber_manual_record,
                        color: Colors.redAccent, size: 14),
                    const SizedBox(width: 8),
                    Text(
                      live.onBreak ? 'ON BREAK' : 'PLAYING',
                      style: TextStyle(
                        color: live.onBreak
                            ? Colors.amberAccent
                            : Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  formatDuration(elapsed),
                  style: const TextStyle(
                    fontSize: 52,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  'time at the table'
                  '${breakTime.inSeconds > 0 ? ' · breaks ${formatDuration(breakTime)}' : ''}',
                  style: const TextStyle(color: Colors.white60),
                ),
                const SizedBox(height: 4),
                Text(
                  '${live.game}${live.stakes.isNotEmpty ? ' · ${live.stakes}' : ''}'
                  '${live.location.isNotEmpty ? ' · ${live.location}' : ''}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Current stack',
                          style: TextStyle(color: Colors.white60)),
                      Text(
                        formatMoney(live.currentStack, store.currency),
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Running result',
                          style: TextStyle(color: Colors.white60)),
                      Text(
                        formatMoney(profit, store.currency),
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: profitColor,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                          'Total buy-in${live.rebuys > 0 ? ' (${live.rebuys} rebuys)' : ''}',
                          style: const TextStyle(color: Colors.white60)),
                      Text(formatMoney(live.buyIn, store.currency)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final v = await _amountDialog(
                      title: 'Update stack',
                      label: 'Current stack',
                      initial: live.currentStack,
                    );
                    if (v != null) await store.updateLiveStack(v);
                  },
                  icon: const Icon(Icons.stacked_bar_chart),
                  label: const Text('Update stack'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final v = await _amountDialog(
                      title: 'Add rebuy',
                      label: 'Rebuy amount',
                    );
                    if (v != null && v > 0) await store.addLiveRebuy(v);
                  },
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Add rebuy'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => store.toggleLiveBreak(),
            icon: Icon(live.onBreak ? Icons.play_arrow : Icons.pause),
            label: Text(live.onBreak ? 'Resume play' : 'Take a break'),
            style: OutlinedButton.styleFrom(
              foregroundColor:
                  live.onBreak ? Colors.amberAccent : Colors.white70,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => _endSession(live),
            icon: const Icon(Icons.stop_circle),
            label: const Text('End session'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade800,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Ending saves the session with your playing time '
            'filled in automatically.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
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
        'date,location,game,stakes,buy_in,cash_out,expenses,profit,hours,notes\n');
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
        s.expenses.toStringAsFixed(0),
        s.profit.toStringAsFixed(0),
        s.hours.toString(),
        _csvEscape(s.notes),
      ].join(','));
    }
    return sb.toString();
  }

  Future<void> _amountSettingDialog(
    BuildContext context, {
    required String title,
    required String label,
    required double initial,
    required Future<void> Function(double) onSave,
  }) async {
    final ctrl = TextEditingController(
        text: initial == 0 ? '' : initial.toStringAsFixed(0));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx,
                  double.tryParse(ctrl.text.replaceAll(',', '').trim())),
              child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    if (v != null) await onSave(v);
  }

  Future<void> _bankrollTxnDialog(BuildContext context,
      {required bool deposit}) async {
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(deposit ? 'Deposit' : 'Withdraw'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: amountCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: 'Amount',
                      border: OutlineInputBorder()),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Note (optional)',
                      border: OutlineInputBorder()),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save')),
            ],
          ),
        ) ??
        false;
    final amount =
        double.tryParse(amountCtrl.text.replaceAll(',', '').trim()) ?? 0;
    if (ok && amount > 0) {
      await store.addBankrollTxn(BankrollTxn(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        date: DateTime.now(),
        amount: deposit ? amount : -amount,
        note: noteCtrl.text.trim(),
      ));
    }
    amountCtrl.dispose();
    noteCtrl.dispose();
  }

  Future<void> _importCsvDialog(BuildContext context) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Import sessions (CSV)'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 8,
              decoration: const InputDecoration(
                hintText: 'Paste CSV exported from Poker Results here…',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Import')),
            ],
          ),
        ) ??
        false;
    if (ok) {
      final parsed = parseCsvSessions(ctrl.text);
      if (parsed.isNotEmpty) {
        await store.addSessions(parsed);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(parsed.isEmpty
              ? 'No sessions found in that CSV'
              : 'Imported ${parsed.length} sessions'),
        ));
      }
    }
    ctrl.dispose();
  }

  Future<void> _importJsonDialog(BuildContext context) async {    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Import backup'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 8,
              decoration: const InputDecoration(
                hintText: 'Paste a Poker Results JSON backup here…',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Import')),
            ],
          ),
        ) ??
        false;
    if (ok) {
      final count = await store.importJson(ctrl.text);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(count >= 0
              ? 'Imported $count sessions'
              : 'That backup could not be read'),
        ));
      }
    }
    ctrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currencyCtrl = TextEditingController(text: store.currency);
    final currency = store.currency;
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
        const SizedBox(height: 28),
        const Text('Bankroll',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          store.bankrollConfigured
              ? 'Current bankroll: ${formatMoney(store.currentBankroll, currency)}'
              : 'Set a starting bankroll to track deposits and withdrawals.',
          style: const TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.savings),
          title: const Text('Starting bankroll'),
          subtitle: Text(formatMoney(store.bankrollStart, currency)),
          trailing: const Icon(Icons.edit),
          onTap: () => _amountSettingDialog(
            context,
            title: 'Starting bankroll',
            label: 'Amount',
            initial: store.bankrollStart,
            onSave: store.setBankrollStart,
          ),
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _bankrollTxnDialog(context, deposit: true),
                icon: const Icon(Icons.arrow_downward),
                label: const Text('Deposit'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _bankrollTxnDialog(context, deposit: false),
                icon: const Icon(Icons.arrow_upward),
                label: const Text('Withdraw'),
              ),
            ),
          ],
        ),
        ...store.bankrollTxns.map((t) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                t.amount >= 0 ? Icons.add_circle : Icons.remove_circle,
                color: t.amount >= 0
                    ? Colors.greenAccent
                    : Colors.redAccent,
                size: 20,
              ),
              title: Text(
                  '${t.amount >= 0 ? 'Deposit' : 'Withdrawal'}${t.note.isNotEmpty ? ' · ${t.note}' : ''}'),
              subtitle: Text(formatDate(t.date)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(formatMoney(t.amount, currency)),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => store.removeBankrollTxn(t.id),
                  ),
                ],
              ),
            )),
        const SizedBox(height: 28),
        const Text('Monthly goal',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.flag),
          title: const Text('Profit target per month'),
          subtitle: Text(store.monthlyGoal > 0
              ? formatMoney(store.monthlyGoal, currency)
              : 'Not set'),
          trailing: const Icon(Icons.edit),
          onTap: () => _amountSettingDialog(
            context,
            title: 'Monthly profit goal',
            label: 'Target amount',
            initial: store.monthlyGoal,
            onSave: store.setMonthlyGoal,
          ),
        ),
        const SizedBox(height: 28),
        const Text('Data', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_download),
          title: const Text('Export sessions as CSV'),
          subtitle: const Text('Copies all sessions to the clipboard'),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: _buildCsv()));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content:
                      Text('CSV copied — paste it into a spreadsheet')));
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_upload),
          title: const Text('Import sessions (CSV)'),
          subtitle: const Text(
              'Bring in sessions exported from an older version'),
          onTap: () => _importCsvDialog(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.backup),
          title: const Text('Export full backup (JSON)'),
          subtitle: const Text(
              'Sessions, bankroll and settings — copies to clipboard'),
          onTap: () async {
            await Clipboard.setData(
                ClipboardData(text: store.exportJson()));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text(
                      'Backup copied — save it somewhere safe')));
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.restore),
          title: const Text('Import backup (JSON)'),
          subtitle: const Text('Replaces current data with the backup'),
          onTap: () => _importJsonDialog(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
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
            if (ok) await store.clearAllSessions();
          },
        ),
        const SizedBox(height: 24),
        const Text(
          'Poker Results v1.1 — data is stored only on this phone. '
          'Export a JSON backup regularly so you never lose your results.',
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
        final titles = ['Poker Results', 'Sessions', 'Stats', 'Settings'];
        return Scaffold(
          appBar: AppBar(title: Text(titles[_tab])),
          body: IndexedStack(
            index: _tab,
            children: const [
              DashboardScreen(),
              SessionsScreen(),
              StatsScreen(),
              SettingsScreen(),
            ],
          ),
          floatingActionButton: (_tab == 2 || _tab == 3)
              ? null
              : FloatingActionButton(
                  onPressed: _openForm,
                  tooltip: 'Add session',
                  child: const Icon(Icons.add),
                ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _tab,
            onTap: (i) => setState(() => _tab = i),
            type: BottomNavigationBarType.fixed,
            items: const [
              BottomNavigationBarItem(
                  icon: Icon(Icons.show_chart), label: 'Dashboard'),
              BottomNavigationBarItem(
                  icon: Icon(Icons.list), label: 'Sessions'),
              BottomNavigationBarItem(
                  icon: Icon(Icons.bar_chart), label: 'Stats'),
              BottomNavigationBarItem(
                  icon: Icon(Icons.settings), label: 'Settings'),
            ],
          ),
        );
      },
    );
  }
}
