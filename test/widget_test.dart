import 'package:flutter_test/flutter_test.dart';
import 'package:poker_results_tracker/main.dart';

PokerSession _s(
  String id,
  DateTime date,
  double buyIn,
  double cashOut,
  double hours,
) {
  return PokerSession(
    id: id,
    date: date,
    location: 'Test Room',
    game: 'PLO5',
    stakes: '25/50',
    buyIn: buyIn,
    cashOut: cashOut,
    hours: hours,
    notes: '',
  );
}

void main() {
  test('profit is cash-out minus buy-in', () {
    final s = _s('1', DateTime(2026, 10, 1), 10000, 15500, 4);
    expect(s.profit, 5500);
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
}
