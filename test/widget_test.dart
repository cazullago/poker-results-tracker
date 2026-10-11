import 'package:flutter_test/flutter_test.dart';
import 'package:poker_results_tracker/main.dart';

PokerSession _s(
  String id,
  DateTime date,
  double buyIn,
  double cashOut,
  double hours, {
  double expenses = 0,
  String game = 'PLO5',
  String location = 'Test Room',
  String stakes = '25/50',
}) {
  return PokerSession(
    id: id,
    date: date,
    location: location,
    game: game,
    stakes: stakes,
    buyIn: buyIn,
    cashOut: cashOut,
    hours: hours,
    expenses: expenses,
    notes: '',
  );
}

void main() {
  test('profit is cash-out minus buy-in', () {
    final s = _s('1', DateTime(2026, 10, 1), 10000, 15500, 4);
    expect(s.profit, 5500);
  });

  test('expenses reduce net profit but not gross', () {
    final s =
        _s('1', DateTime(2026, 10, 1), 10000, 15500, 4, expenses: 500);
    expect(s.grossProfit, 5500);
    expect(s.profit, 5000);
  });

  test('stats aggregate correctly', () {
    final stats = computeStats([
      _s('2', DateTime(2026, 10, 2), 10000, 8000, 3), // -2000
      _s('1', DateTime(2026, 10, 1), 10000, 15500, 4), // +5500
      _s('3', DateTime(2026, 10, 3), 5000, 5000, 2), // 0
    ]);
    expect(stats.count, 3);
    expect(stats.totalProfit, 3500);
    expect(stats.hours, 9);
    expect(stats.cumulative, [5500, 3500, 3500]);
    expect(stats.winRate, closeTo(1 / 3, 0.001));
    expect(stats.best, 5500);
    expect(stats.worst, -2000);
  });

  test('stats handle empty list', () {
    final stats = computeStats([]);
    expect(stats.count, 0);
    expect(stats.totalProfit, 0);
    expect(stats.cumulative, isEmpty);
  });

  test('money formatting uses thousands separators and sign', () {
    expect(formatMoney(5500, '₱'), '₱5,500');
    expect(formatMoney(-2000, '₱'), '-₱2,000');
    expect(formatMoney(0, '\$'), '\$0');
    expect(formatMoney(1234567, '₱'), '₱1,234,567');
  });

  test('duration formatting reads like a session clock', () {
    expect(formatDuration(const Duration(hours: 3, minutes: 32, seconds: 5)),
        '3h 32m 05s');
    expect(formatDuration(const Duration(minutes: 7, seconds: 9)),
        '07m 09s');
  });

  test('live session clock excludes completed and current breaks', () {
    final live = LiveSession(
      id: 'x',
      startTime: DateTime(2026, 10, 11, 10, 0),
      location: 'Wild Aces',
      game: 'PLO5',
      stakes: '25/50',
      buyIn: 10000,
      currentStack: 10000,
      breakSeconds: 1800, // 30m break already taken
    );
    // 10:00 -> 13:32 is 3h32 wall time, minus 30m break = 3h02 played
    expect(live.elapsed(DateTime(2026, 10, 11, 13, 32)),
        const Duration(hours: 3, minutes: 2));
    // now on a break since 13:00
    live.breakStart = DateTime(2026, 10, 11, 13, 0);
    expect(live.elapsed(DateTime(2026, 10, 11, 13, 32)),
        const Duration(hours: 2, minutes: 30));
    expect(live.totalBreak(DateTime(2026, 10, 11, 13, 32)),
        const Duration(hours: 1, minutes: 2));
  });

  test('live profit is stack minus total buy-in', () {
    final live = LiveSession(
      id: 'x',
      startTime: DateTime(2026, 10, 11, 10, 0),
      location: '',
      game: 'PLO5',
      stakes: '',
      buyIn: 15000, // includes a rebuy
      currentStack: 21000,
    );
    expect(live.liveProfit, 6000);
  });

  test('big blind parses from stakes and drives BB stats', () {
    expect(bigBlindOf('25/50'), 50);
    expect(bigBlindOf('50/100'), 100);
    expect(bigBlindOf(''), isNull);
    final s = _s('1', DateTime(2026, 10, 1), 10000, 15000, 5);
    expect(s.profitInBB, 100); // 5000 / 50
    expect(s.bbPerHour, 20);
  });

  test('breakdowns group by game and month buckets sum profits', () {
    final sessions = [
      _s('1', DateTime(2026, 9, 5), 10000, 15000, 4, game: 'PLO5'),
      _s('2', DateTime(2026, 9, 20), 10000, 8000, 3, game: 'NLHE'),
      _s('3', DateTime(2026, 10, 2), 5000, 9000, 2, game: 'PLO5'),
    ];
    final byGame = breakdownBy(sessions, (s) => s.game);
    expect(byGame.first.name, 'PLO5');
    expect(byGame.first.profit, 9000);
    expect(byGame.first.count, 2);

    final buckets = monthlyBuckets(sessions);
    expect(buckets.length, 2);
    expect(buckets[0].profit, 3000); // Sep: +5000 -2000
    expect(buckets[1].profit, 4000); // Oct: +4000
  });

  test('streaks: current and longest', () {
    final desc = [
      _s('3', DateTime(2026, 10, 3), 5000, 9000, 2), // W
      _s('2', DateTime(2026, 10, 2), 5000, 7000, 2), // W
      _s('1', DateTime(2026, 10, 1), 5000, 3000, 2), // L
    ];
    final (kind, n) = currentStreak(desc);
    expect(kind, 'W');
    expect(n, 2);
    expect(longestWinStreak(desc), 2);
  });

  test('CSV import parses v1.0 export format including quoted fields', () {
    const csv = 'date,location,game,stakes,buy_in,cash_out,profit,hours,notes\n'
        '2026-10-05T20:00:00.000,"Wild Aces, Angeles",PLO5,"25/50",10000,15500,5500,4.5,"good game"\n'
        '2026-10-06T20:00:00.000,"Royce",NLHE,"50/100",20000,12000,-8000,3,\n'
        'bad,row,here\n';
    final parsed = parseCsvSessions(csv);
    expect(parsed.length, 2);
    expect(parsed[0].location, 'Wild Aces, Angeles');
    expect(parsed[0].profit, 5500);
    expect(parsed[0].hours, 4.5);
    expect(parsed[1].game, 'NLHE');
    expect(parsed[1].profit, -8000);
  });
}
