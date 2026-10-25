// =====================================================================
//  LUDO GAME  (App 1)
//  Classic 4-player Ludo on one phone (pass & play).
//  Listens on port 4040 so the "Ludo Controller" app can set dice numbers.
// =====================================================================
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ==== LOGIC START ====
const List<String> kNames = ['Red', 'Green', 'Yellow', 'Blue'];
// Absolute track index where each colour enters the board.
const List<int> kStart = [0, 13, 26, 39];
// Safe squares: the 4 start squares + the 4 star squares.
const Set<int> kSafe = {0, 8, 13, 21, 26, 34, 39, 47};
const int kTrackLen = 52;
// Token position: -1 = in base, 0..50 = main track, 51..55 = home column, 56 = home.
const int kFinished = 56;

// The 52 main-track cells as [row, col] on a 15x15 grid, clockwise from Red's start.
const List<List<int>> kTrack = [
  [6, 1], [6, 2], [6, 3], [6, 4], [6, 5],
  [5, 6], [4, 6], [3, 6], [2, 6], [1, 6], [0, 6],
  [0, 7], [0, 8],
  [1, 8], [2, 8], [3, 8], [4, 8], [5, 8],
  [6, 9], [6, 10], [6, 11], [6, 12], [6, 13], [6, 14],
  [7, 14], [8, 14],
  [8, 13], [8, 12], [8, 11], [8, 10], [8, 9],
  [9, 8], [10, 8], [11, 8], [12, 8], [13, 8], [14, 8],
  [14, 7], [14, 6],
  [13, 6], [12, 6], [11, 6], [10, 6], [9, 6],
  [8, 5], [8, 4], [8, 3], [8, 2], [8, 1], [8, 0],
  [7, 0], [6, 0],
];

int absIndex(int color, int rel) => (kStart[color] + rel) % kTrackLen;

class Capture {
  final int color;
  final int index;
  const Capture(this.color, this.index);
}

enum RollKind { lost, noMove, canMove }

class RollOutcome {
  final RollKind kind;
  final List<int> movable;
  const RollOutcome(this.kind, [this.movable = const <int>[]]);
}

class MoveOutcome {
  final int to;
  final List<Capture> captures;
  final bool finishedToken;
  final bool playerDone;
  final bool extraTurn;
  const MoveOutcome(this.to, this.captures, this.finishedToken, this.playerDone, this.extraTurn);
}

// Colour indexes used in each mode. 2 players = Red vs Yellow (opposite corners).
const List<int> kTwoPlayers = [0, 2];
const List<int> kFourPlayers = [0, 1, 2, 3];

class LudoEngine {
  /// Colours taking part, in turn order.
  final List<int> players;
  final List<List<int>> rel = List.generate(4, (_) => List<int>.filled(4, -1));
  int current = 0;
  int dice = 0;
  int sixes = 0;
  bool over = false;
  final List<int> ranking = [];

  LudoEngine([this.players = const <int>[0, 1, 2, 3]]) {
    current = players.first;
  }

  bool isDone(int c) => ranking.contains(c);

  List<int> movableTokens(int c, int d) {
    final out = <int>[];
    for (var t = 0; t < 4; t++) {
      final r = rel[c][t];
      if (r == -1) {
        if (d == 6) out.add(t);
      } else if (r < kFinished && r + d <= kFinished) {
        out.add(t);
      }
    }
    return out;
  }

  RollOutcome onRoll(int value) {
    dice = value;
    if (value == 6) {
      sixes++;
    } else {
      sixes = 0;
    }
    if (sixes >= 3) {
      sixes = 0;
      return const RollOutcome(RollKind.lost);
    }
    final m = movableTokens(current, value);
    if (m.isEmpty) return const RollOutcome(RollKind.noMove);
    return RollOutcome(RollKind.canMove, m);
  }

  MoveOutcome move(int t) {
    final c = current;
    final from = rel[c][t];
    final to = from == -1 ? 0 : from + dice;
    rel[c][t] = to;
    final captures = <Capture>[];
    if (to <= 50) {
      final a = absIndex(c, to);
      if (!kSafe.contains(a)) {
        for (var oc = 0; oc < 4; oc++) {
          if (oc == c) continue;
          for (var ot = 0; ot < 4; ot++) {
            final orl = rel[oc][ot];
            if (orl >= 0 && orl <= 50 && absIndex(oc, orl) == a) {
              rel[oc][ot] = -1;
              captures.add(Capture(oc, ot));
            }
          }
        }
      }
    }
    final finishedToken = to == kFinished;
    var playerDone = false;
    if (finishedToken && rel[c].every((r) => r == kFinished)) {
      playerDone = true;
      ranking.add(c);
      if (ranking.length >= players.length - 1) {
        for (final p in players) {
          if (!ranking.contains(p)) ranking.add(p);
        }
        over = true;
      }
    }
    final extra = !playerDone && (dice == 6 || captures.isNotEmpty || finishedToken);
    return MoveOutcome(to, captures, finishedToken, playerDone, extra);
  }

  void endTurn(bool extra) {
    if (over) return;
    if (extra && !isDone(current)) return; // same player rolls again
    sixes = 0;
    var i = players.indexOf(current);
    for (var k = 0; k < players.length; k++) {
      i = (i + 1) % players.length;
      if (!isDone(players[i])) break;
    }
    current = players[i];
  }
}
// ==== LOGIC END ====

// ---------------------------------------------------------------------
//  Link to the controller app (plain TCP, one JSON message per line)
// ---------------------------------------------------------------------
class ControllerLink extends ChangeNotifier {
  ControllerLink._();
  static final ControllerLink I = ControllerLink._();
  static const int port = 4040;

  ServerSocket? _server;
  Socket? _client;
  int? forced; // dice number chosen on the controller (used once)
  int turnColor = -1;
  int playerCount = 0; // 2 or 4 while a game is on, 0 on the menu
  String phase = 'idle';
  List<String> ips = [];
  bool _pending = false;

  bool get connected => _client != null;
  String get ipText => ips.join('  /  ');

  void _changed() {
    if (_pending) return;
    _pending = true;
    scheduleMicrotask(() {
      _pending = false;
      notifyListeners();
    });
  }

  Future<void> start() async {
    await refreshIps();
    if (_server != null) return;
    try {
      final s = await ServerSocket.bind(InternetAddress.anyIPv4, port, shared: true);
      _server = s;
      s.listen(_onClient, onError: (Object _) {});
    } catch (_) {
      _server = null;
    }
  }

  Future<void> refreshIps() async {
    final found = <String>[];
    try {
      final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in list) {
        for (final a in i.addresses) {
          if (!a.address.startsWith('169.254.')) found.add(a.address);
        }
      }
    } catch (_) {}
    ips = found;
    _changed();
  }

  void _onClient(Socket s) {
    final old = _client;
    _client = s;
    try {
      old?.destroy();
    } catch (_) {}
    try {
      s.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    s.done.catchError((Object _) {});
    _sendTo(s, {'t': 'hello'});
    _broadcast();
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onDone: () => _dropped(s),
          onError: (Object _) => _dropped(s),
          cancelOnError: true,
        );
    _changed();
  }

  void _dropped(Socket s) {
    if (identical(_client, s)) {
      _client = null;
      forced = null;
      _changed();
    }
    try {
      s.destroy();
    } catch (_) {}
  }

  void _onLine(String line) {
    try {
      final m = jsonDecode(line);
      if (m is Map) {
        final t = m['t'];
        if (t == 'set') {
          final v = m['v'];
          if (v is int && v >= 1 && v <= 6) forced = v;
        } else if (t == 'clear') {
          forced = null;
        }
        _broadcast();
        _changed();
      }
    } catch (_) {}
  }

  void _sendTo(Socket s, Map<String, dynamic> m) {
    try {
      s.write('${jsonEncode(m)}\n');
    } catch (_) {}
  }

  void _broadcast() {
    final s = _client;
    if (s == null) return;
    _sendTo(s, {
      't': 'state',
      'c': turnColor,
      'name': turnColor >= 0 ? kNames[turnColor] : '',
      'p': phase,
      'np': playerCount,
      'sel': forced,
    });
  }

  /// Called by the game whenever the turn / phase changes.
  void publish(int color, String ph, [int np = 0]) {
    turnColor = color;
    phase = ph;
    playerCount = np;
    _broadcast();
    _changed();
  }

  /// Called when the dice is rolled. Returns the controller's number (once) or null.
  int? takeForced() {
    if (!connected) {
      forced = null;
      return null;
    }
    final f = forced;
    forced = null;
    _broadcast();
    _changed();
    return f;
  }
}

// ---------------------------------------------------------------------
//  Colours + board geometry
// ---------------------------------------------------------------------
const List<Color> kColors = [
  Color(0xFFE53935), // red
  Color(0xFF43A047), // green
  Color(0xFFFDD835), // yellow
  Color(0xFF1E88E5), // blue
];
const List<Color> kDeep = [
  Color(0xFF8E1B1B),
  Color(0xFF1B5E20),
  Color(0xFFB28704),
  Color(0xFF0D47A1),
];

/// Rotate a point 90 degrees clockwise around the board centre, [times] times.
Offset rotCw(Offset p, int times) {
  var q = p;
  for (var i = 0; i < times; i++) {
    q = Offset(15 - q.dy, q.dx);
  }
  return q;
}

/// Centre of a token in grid units (x = column, y = row).
Offset tokenGridPos(int color, int idx, int rel) {
  if (rel == -1) {
    const slots = [Offset(2, 2), Offset(4, 2), Offset(2, 4), Offset(4, 4)];
    return rotCw(slots[idx], color);
  }
  if (rel <= 50) {
    final cell = kTrack[absIndex(color, rel)];
    return Offset(cell[1] + 0.5, cell[0] + 0.5);
  }
  if (rel <= 55) {
    final k = rel - 51;
    return rotCw(Offset(1.5 + k, 7.5), color);
  }
  return rotCw(Offset(6.55, 7.5 + (idx - 1.5) * 0.4), color);
}

Path _star(Offset c, double r) {
  final path = Path();
  for (var i = 0; i < 10; i++) {
    final rad = i.isEven ? r : r * 0.45;
    final a = -pi / 2 + i * pi / 5;
    final p = Offset(c.dx + rad * cos(a), c.dy + rad * sin(a));
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  path.close();
  return path;
}

class BoardPainter extends CustomPainter {
  const BoardPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 15;
    final paint = Paint();
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.black26;

    paint.color = Colors.white;
    canvas.drawRect(Offset.zero & size, paint);

    // Bases
    final origins = [
      const Offset(0, 0),
      const Offset(9, 0),
      const Offset(9, 9),
      const Offset(0, 9),
    ];
    for (var c = 0; c < 4; c++) {
      final o = origins[c];
      paint.color = kColors[c];
      canvas.drawRect(Rect.fromLTWH(o.dx * u, o.dy * u, 6 * u, 6 * u), paint);
      paint.color = Colors.white;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH((o.dx + 1) * u, (o.dy + 1) * u, 4 * u, 4 * u),
          Radius.circular(u * 0.5),
        ),
        paint,
      );
      for (var i = 0; i < 4; i++) {
        final p = tokenGridPos(c, i, -1);
        paint.color = kColors[c].withAlpha(80);
        canvas.drawCircle(Offset(p.dx * u, p.dy * u), u * 0.62, paint);
      }
    }

    void cell(int r, int col, Color fill) {
      final rect = Rect.fromLTWH(col * u, r * u, u, u);
      paint.color = fill;
      canvas.drawRect(rect, paint);
      canvas.drawRect(rect, line);
    }

    // Main track
    for (var i = 0; i < kTrackLen; i++) {
      final r = kTrack[i][0];
      final col = kTrack[i][1];
      final si = kStart.indexOf(i);
      cell(r, col, si >= 0 ? kColors[si] : Colors.white);
      if (kSafe.contains(i)) {
        paint.color = si >= 0 ? Colors.white : Colors.black38;
        canvas.drawPath(_star(Offset((col + 0.5) * u, (r + 0.5) * u), u * 0.36), paint);
      }
    }

    // Home columns
    for (var c = 0; c < 4; c++) {
      for (var k = 0; k < 5; k++) {
        final p = rotCw(Offset(1.5 + k, 7.5), c);
        cell((p.dy - 0.5).round(), (p.dx - 0.5).round(), kColors[c]);
      }
    }

    // Centre triangles
    final centre = Offset(7.5 * u, 7.5 * u);
    final edges = [
      [Offset(6 * u, 6 * u), Offset(6 * u, 9 * u)],
      [Offset(6 * u, 6 * u), Offset(9 * u, 6 * u)],
      [Offset(9 * u, 6 * u), Offset(9 * u, 9 * u)],
      [Offset(6 * u, 9 * u), Offset(9 * u, 9 * u)],
    ];
    for (var c = 0; c < 4; c++) {
      final path = Path()
        ..moveTo(edges[c][0].dx, edges[c][0].dy)
        ..lineTo(edges[c][1].dx, edges[c][1].dy)
        ..lineTo(centre.dx, centre.dy)
        ..close();
      paint.color = kColors[c];
      canvas.drawPath(path, paint);
      canvas.drawPath(path, line);
    }

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black54;
    canvas.drawRect(Offset.zero & size, border);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class TokenView extends StatelessWidget {
  final Color color;
  final Color deep;
  final double d;
  final bool glow;
  final double pulse;
  const TokenView({
    super.key,
    required this.color,
    required this.deep,
    required this.d,
    required this.glow,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (glow)
            Container(
              width: d * 1.25,
              height: d * 1.25,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2 + pulse * 2),
                boxShadow: [
                  BoxShadow(
                    color: color.withAlpha(200),
                    blurRadius: 6 + pulse * 8,
                    spreadRadius: 1 + pulse * 3,
                  ),
                ],
              ),
            ),
          Container(
            width: d,
            height: d,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(color: Colors.white, width: max(1.5, d * 0.09)),
              boxShadow: const [
                BoxShadow(color: Colors.black38, blurRadius: 3, offset: Offset(0, 1.5)),
              ],
            ),
            child: Center(
              child: Container(
                width: d * 0.3,
                height: d * 0.3,
                decoration: BoxDecoration(shape: BoxShape.circle, color: deep),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DicePainter extends CustomPainter {
  final int face;
  final Color color;
  const DicePainter(this.face, this.color);

  static const List<List<List<int>>> _pips = [
    [],
    [
      [1, 1]
    ],
    [
      [0, 0],
      [2, 2]
    ],
    [
      [0, 0],
      [1, 1],
      [2, 2]
    ],
    [
      [0, 0],
      [2, 0],
      [0, 2],
      [2, 2]
    ],
    [
      [0, 0],
      [2, 0],
      [1, 1],
      [0, 2],
      [2, 2]
    ],
    [
      [0, 0],
      [2, 0],
      [0, 1],
      [2, 1],
      [0, 2],
      [2, 2]
    ],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (face < 1 || face > 6) return;
    final paint = Paint()..color = color;
    for (final p in _pips[face]) {
      final x = size.width * (0.17 + 0.33 * p[0]);
      final y = size.height * (0.17 + 0.33 * p[1]);
      canvas.drawCircle(Offset(x, y), size.width * 0.1, paint);
    }
  }

  @override
  bool shouldRepaint(covariant DicePainter old) => old.face != face || old.color != color;
}

// ---------------------------------------------------------------------
//  Game model (turn flow, animation, controller hook)
// ---------------------------------------------------------------------
enum Phase { roll, rolling, choose, moving, over }

class GameModel extends ChangeNotifier {
  final List<int> players;
  late LudoEngine engine;
  final Random _rng = Random();
  List<List<int>> viewRel = _fresh();
  Phase phase = Phase.roll;
  int face = 0;
  String status = '';
  List<int> movable = [];
  int movingId = -1;
  bool _disposed = false;
  int _gen = 0;

  static List<List<int>> _fresh() => List.generate(4, (_) => List<int>.filled(4, -1));

  GameModel(this.players) {
    engine = LudoEngine(players);
    _setRollStatus(false);
    scheduleMicrotask(_publish);
  }

  @override
  void dispose() {
    _disposed = true;
    ControllerLink.I.publish(-1, 'idle');
    super.dispose();
  }

  void _n() {
    if (!_disposed) notifyListeners();
  }

  String _phaseName() {
    if (phase == Phase.roll) return 'roll';
    if (phase == Phase.rolling) return 'rolling';
    if (phase == Phase.over) return 'over';
    return 'move';
  }

  void _publish() {
    if (_disposed) return;
    ControllerLink.I.publish(engine.current, _phaseName(), players.length);
  }

  void _setRollStatus(bool again) {
    final n = kNames[engine.current];
    status = again ? '$n rolls again!' : "$n's turn — tap the dice";
  }

  Future<bool> _pause(int ms, int g) async {
    await Future.delayed(Duration(milliseconds: ms));
    return !(_disposed || g != _gen);
  }

  void reset() {
    _gen++;
    engine = LudoEngine(players);
    viewRel = _fresh();
    phase = Phase.roll;
    face = 0;
    movable = [];
    movingId = -1;
    _setRollStatus(false);
    _publish();
    _n();
  }

  void _next(bool extra) {
    engine.endTurn(extra);
    movable = [];
    movingId = -1;
    phase = Phase.roll;
    _setRollStatus(extra);
    _publish();
    _n();
  }

  Future<void> roll() async {
    if (phase != Phase.roll) return;
    final g = _gen;
    phase = Phase.rolling;
    status = '${kNames[engine.current]} is rolling...';
    _publish();
    _n();

    // If the controller is connected and a number was picked, use it. Otherwise random.
    final forced = ControllerLink.I.takeForced();
    final value = forced ?? (_rng.nextInt(6) + 1);

    for (var i = 0; i < 8; i++) {
      if (!await _pause(70, g)) return;
      face = _rng.nextInt(6) + 1;
      _n();
    }
    face = value;
    _n();
    if (!await _pause(380, g)) return;

    final e = engine;
    final name = kNames[e.current];
    final out = e.onRoll(value);

    if (out.kind == RollKind.lost) {
      status = '$name rolled three 6s in a row — turn lost!';
      _n();
      if (!await _pause(1300, g)) return;
      _next(false);
      return;
    }
    if (out.kind == RollKind.noMove) {
      status = '$name rolled $value — no move possible';
      _n();
      if (!await _pause(1100, g)) return;
      _next(false);
      return;
    }

    final m = out.movable;
    final firstRel = e.rel[e.current][m.first];
    final allSame = m.every((t) => e.rel[e.current][t] == firstRel);
    if (m.length == 1 || allSame) {
      status = '$name rolled $value';
      _n();
      if (!await _pause(300, g)) return;
      await _move(m.first, g);
    } else {
      movable = m;
      phase = Phase.choose;
      status = '$name rolled $value — tap a glowing token';
      _publish();
      _n();
    }
  }

  void tapToken(int c, int t) {
    if (phase != Phase.choose) return;
    if (c != engine.current || !movable.contains(t)) return;
    _move(t, _gen);
  }

  Future<void> _move(int t, int g) async {
    final e = engine;
    final c = e.current;
    phase = Phase.moving;
    movable = [];
    movingId = c * 4 + t;
    _publish();
    _n();

    final from = e.rel[c][t];
    final out = e.move(t);
    if (from == -1) {
      viewRel[c][t] = 0;
      _n();
      if (!await _pause(260, g)) return;
    } else {
      for (var s = from + 1; s <= out.to; s++) {
        viewRel[c][t] = s;
        _n();
        if (!await _pause(170, g)) return;
      }
    }

    if (out.captures.isNotEmpty) {
      for (final cp in out.captures) {
        viewRel[cp.color][cp.index] = -1;
      }
      final victims = out.captures.map((x) => kNames[x.color]).toSet().join(' & ');
      status = '${kNames[c]} captured $victims!';
      _n();
      if (!await _pause(800, g)) return;
    } else if (out.finishedToken) {
      status = '${kNames[c]} got a token home!';
      _n();
      if (!await _pause(600, g)) return;
    }

    movingId = -1;
    if (e.over) {
      phase = Phase.over;
      status = 'Game over';
      _publish();
      _n();
      return;
    }
    if (out.playerDone) {
      status = '${kNames[c]} has finished all tokens!';
      _n();
      if (!await _pause(1000, g)) return;
    }
    _next(out.extraTurn);
  }
}

// ---------------------------------------------------------------------
//  App + screens
// ---------------------------------------------------------------------
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const LudoApp());
}

class LudoApp extends StatelessWidget {
  const LudoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ludo Game',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF6C4DFF),
      ),
      home: const StartScreen(),
    );
  }
}

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  bool showModes = false;

  @override
  void initState() {
    super.initState();
    ControllerLink.I.start();
  }

  Widget _startButton() {
    return ElevatedButton(
      key: const ValueKey('start'),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFFFFC107),
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 64, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
      onPressed: () => setState(() => showModes = true),
      child: const Text(
        'START',
        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 4),
      ),
    );
  }

  Widget _modeCard(String title, String sub, List<int> players) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => GameScreen(players: players)),
      ),
      child: Container(
        width: 270,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(30),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white54, width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 2),
            ),
            const SizedBox(height: 4),
            Text(sub, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final c in players)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(color: kColors[c], shape: BoxShape.circle),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _modes() {
    return Column(
      key: const ValueKey('modes'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _modeCard('2 PLAYERS', 'Red vs Yellow · pass the phone', kTwoPlayers),
        const SizedBox(height: 14),
        _modeCard('4 PLAYERS', 'Classic Ludo · pass the phone', kFourPlayers),
      ],
    );
  }

  Widget _footer() {
    final l = ControllerLink.I;
    if (l.connected) {
      return const Text(
        '🎮 Controller connected',
        style: TextStyle(color: Color(0xFF7CFFB2), fontSize: 14),
      );
    }
    if (l.ipText.isEmpty) return const SizedBox(height: 18);
    return Text(
      'Controller address: ${l.ipText}',
      style: const TextStyle(color: Colors.white54, fontSize: 13),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2B1B6B), Color(0xFF0E0A2A)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              const Text(
                'LUDO',
                style: TextStyle(
                  fontSize: 72,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 10,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var c = 0; c < 4; c++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: kColors[c],
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                ],
              ),
              const Spacer(flex: 2),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 450),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: ScaleTransition(scale: anim, child: child),
                ),
                child: showModes ? _modes() : _startButton(),
              ),
              const Spacer(flex: 3),
              AnimatedBuilder(
                animation: ControllerLink.I,
                builder: (context, _) => _footer(),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class GameScreen extends StatefulWidget {
  final List<int> players;
  const GameScreen({super.key, required this.players});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with SingleTickerProviderStateMixin {
  late final GameModel game;
  late final AnimationController pulse;

  @override
  void initState() {
    super.initState();
    game = GameModel(widget.players);
    pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    pulse.dispose();
    game.dispose();
    super.dispose();
  }

  Future<void> _confirm(String title, String body, VoidCallback onYes) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('No')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Yes')),
        ],
      ),
    );
    if (ok == true && mounted) onYes();
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => _confirm('Quit game?', 'Go back to the home screen?', () {
              Navigator.of(context).pop();
            }),
          ),
          const Text(
            'LUDO',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: 4,
            ),
          ),
          const Spacer(),
          if (ControllerLink.I.connected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1B5E20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                '🎮 Controller',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () => _confirm('Restart?', 'Start a new game?', game.reset),
          ),
        ],
      ),
    );
  }

  Widget _board(double s) {
    final u = s / 15;
    final groups = <String, List<int>>{};
    for (final c in game.players) {
      for (var i = 0; i < 4; i++) {
        final rel = game.viewRel[c][i];
        if (rel >= 0 && rel <= 55) {
          final p = tokenGridPos(c, i, rel);
          groups.putIfAbsent('${p.dx.floor()}_${p.dy.floor()}', () => <int>[]).add(c * 4 + i);
        }
      }
    }

    final normal = <Widget>[];
    final top = <Widget>[];
    for (final c in game.players) {
      for (var i = 0; i < 4; i++) {
        final id = c * 4 + i;
        final rel = game.viewRel[c][i];
        var p = tokenGridPos(c, i, rel);
        var scale = 1.0;
        if (rel >= 0 && rel <= 55) {
          final g = groups['${p.dx.floor()}_${p.dy.floor()}']!;
          if (g.length > 1) {
            final k = g.indexOf(id);
            final a = 2 * pi * k / g.length - pi / 2;
            p = p + Offset(cos(a), sin(a)) * 0.22;
            scale = 0.72;
          }
        } else if (rel == kFinished) {
          scale = 0.55;
        }
        final glow = game.phase == Phase.choose && c == game.engine.current && game.movable.contains(i);
        final d = u * 0.8 * scale;
        final box = max(d, u * 0.95);
        final w = AnimatedPositioned(
          key: ValueKey('tok$id'),
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeInOut,
          left: p.dx * u - box / 2,
          top: p.dy * u - box / 2,
          width: box,
          height: box,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => game.tapToken(c, i),
            child: Center(
              child: TokenView(
                color: kColors[c],
                deep: kDeep[c],
                d: d,
                glow: glow,
                pulse: pulse.value,
              ),
            ),
          ),
        );
        if (glow || game.movingId == id) {
          top.add(w);
        } else {
          normal.add(w);
        }
      }
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        CustomPaint(size: Size(s, s), painter: const BoardPainter()),
        ...normal,
        ...top,
      ],
    );
  }

  Widget _chip(int p) {
    final isCur = game.engine.current == p && game.phase != Phase.over;
    final home = game.viewRel[p].where((r) => r == kFinished).length;
    final textColor = isCur ? (p == 2 ? Colors.black : Colors.white) : Colors.white70;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: isCur ? kColors[p] : kColors[p].withAlpha(60),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isCur ? Colors.white : Colors.transparent, width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            kNames[p],
            style: TextStyle(color: textColor, fontWeight: FontWeight.w700, fontSize: 13),
          ),
          Text('$home/4 home', style: TextStyle(color: textColor, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _dice(int c) {
    final active = game.phase == Phase.roll;
    final glow = active ? 0.4 + 0.6 * pulse.value : 0.0;
    return GestureDetector(
      onTap: () => game.roll(),
      child: Container(
        width: 78,
        height: 78,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kColors[c], width: 4),
          boxShadow: [
            BoxShadow(
              color: kColors[c].withAlpha((glow * 200).round()),
              blurRadius: 6 + 14 * glow,
              spreadRadius: 1 + 3 * glow,
            ),
          ],
        ),
        child: game.face == 0
            ? Center(
                child: Text(
                  'ROLL',
                  style: TextStyle(fontWeight: FontWeight.w900, color: kDeep[c], fontSize: 16),
                ),
              )
            : SizedBox.expand(child: CustomPaint(painter: DicePainter(game.face, kDeep[c]))),
      ),
    );
  }

  Widget _bottomPanel() {
    final c = game.engine.current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              for (final p in game.players) Expanded(child: _chip(p)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _dice(c),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  game.status,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _rankRow(int place, int color) {
    const medals = ['🥇', '🥈', '🥉', '4th'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            child: Text(medals[place], style: const TextStyle(fontSize: 24, color: Colors.white)),
          ),
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(color: kColors[color], shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            kNames[color],
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _resultOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withAlpha(215),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '🏆 Game Over',
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: Colors.white),
              ),
              const SizedBox(height: 20),
              for (var i = 0; i < game.engine.ranking.length; i++)
                _rankRow(i, game.engine.ranking[i]),
              const SizedBox(height: 28),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(onPressed: game.reset, child: const Text('Play again')),
                  const SizedBox(width: 14),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Home'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF14142B),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([game, ControllerLink.I, pulse]),
          builder: (context, _) {
            return Stack(
              children: [
                Column(
                  children: [
                    _topBar(),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, cons) {
                          final s = min(cons.maxWidth - 12, cons.maxHeight - 4);
                          return Center(
                            child: SizedBox(width: s, height: s, child: _board(s)),
                          );
                        },
                      ),
                    ),
                    _bottomPanel(),
                  ],
                ),
                if (game.phase == Phase.over) _resultOverlay(),
              ],
            );
          },
        ),
      ),
    );
  }
}
