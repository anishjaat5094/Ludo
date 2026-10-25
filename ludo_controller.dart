// =====================================================================
//  LUDO CONTROLLER  (App 2)
//  Connects to the Ludo Game app over the same Wi-Fi and lets you pick
//  the dice number for whoever's turn it is.
// =====================================================================
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int kPort = 4040;
const List<String> kNames = ['Red', 'Green', 'Yellow', 'Blue'];
const List<Color> kColors = [
  Color(0xFFE53935),
  Color(0xFF43A047),
  Color(0xFFFDD835),
  Color(0xFF1E88E5),
];

// ---------------------------------------------------------------------
//  Connection to the game
// ---------------------------------------------------------------------
class Conn extends ChangeNotifier {
  Socket? _s;
  bool connected = false;
  bool busy = false;
  bool _dead = false;
  String message = '';
  int color = -1;
  String name = '';
  String phase = 'idle';
  int players = 0; // 2 or 4 while a game is on
  int? sel;

  void _n() {
    if (!_dead) notifyListeners();
  }

  @override
  void dispose() {
    _dead = true;
    try {
      _s?.destroy();
    } catch (_) {}
    super.dispose();
  }

  Future<List<String>> _localIps() async {
    final wifi = <String>[];
    final other = <String>[];
    try {
      final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in list) {
        final nm = i.name.toLowerCase();
        for (final a in i.addresses) {
          if (a.address.startsWith('169.254.')) continue;
          if (nm.startsWith('wlan') ||
              nm.startsWith('ap') ||
              nm.startsWith('swlan') ||
              nm.startsWith('eth')) {
            wifi.add(a.address);
          } else {
            other.add(a.address);
          }
        }
      }
    } catch (_) {}
    return wifi.isNotEmpty ? wifi : other;
  }

  /// Probe every address on the local network for the game (port 4040).
  Future<String?> _scan() async {
    final ips = await _localIps();
    final hosts = <String>[];
    for (final ip in ips) {
      final p = ip.split('.');
      if (p.length != 4) continue;
      final base = '${p[0]}.${p[1]}.${p[2]}';
      for (var i = 1; i < 255; i++) {
        final h = '$base.$i';
        if (h != ip && !hosts.contains(h)) hosts.add(h);
      }
    }
    if (hosts.isEmpty) return null;
    final done = Completer<String?>();
    var pending = hosts.length;
    for (final h in hosts) {
      Socket.connect(h, kPort, timeout: const Duration(milliseconds: 800))
          .then((s) {
            s.destroy();
            if (!done.isCompleted) done.complete(h);
          })
          .catchError((Object _) {})
          .whenComplete(() {
            pending--;
            if (pending == 0 && !done.isCompleted) done.complete(null);
          });
    }
    return done.future;
  }

  Future<void> autoConnect() async {
    if (busy) return;
    busy = true;
    message = 'Looking for the Ludo game on this Wi-Fi...';
    _n();
    final host = await _scan();
    if (_dead) return;
    if (host == null) {
      busy = false;
      message = 'Game not found. Open the Ludo Game app on the other phone, make sure both phones '
          'are on the same Wi-Fi, then try again (or type its address below).';
      _n();
      return;
    }
    await connect(host);
  }

  Future<void> connect(String host) async {
    busy = true;
    message = 'Connecting to $host ...';
    _n();
    try {
      final s = await Socket.connect(host.trim(), kPort, timeout: const Duration(seconds: 3));
      try {
        s.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      try {
        _s?.destroy();
      } catch (_) {}
      _s = s;
      connected = true;
      busy = false;
      message = '';
      s.done.catchError((Object _) {});
      s
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _onLine,
            onDone: () => _lost(s),
            onError: (Object _) => _lost(s),
            cancelOnError: true,
          );
    } catch (_) {
      connected = false;
      busy = false;
      message = 'Could not connect to $host';
    }
    _n();
  }

  void _lost(Socket s) {
    if (identical(_s, s)) {
      _s = null;
      connected = false;
      color = -1;
      name = '';
      phase = 'idle';
      players = 0;
      sel = null;
      message = 'Disconnected from the game';
      _n();
    }
    try {
      s.destroy();
    } catch (_) {}
  }

  void _onLine(String line) {
    try {
      final m = jsonDecode(line);
      if (m is Map && m['t'] == 'state') {
        final c = m['c'];
        color = c is int ? c : -1;
        final nm = m['name'];
        name = nm is String ? nm : '';
        final p = m['p'];
        phase = p is String ? p : 'idle';
        final np = m['np'];
        players = np is int ? np : 0;
        final sv = m['sel'];
        sel = sv is int ? sv : null;
        _n();
      }
    } catch (_) {}
  }

  void _send(Map<String, dynamic> m) {
    try {
      _s?.write('${jsonEncode(m)}\n');
    } catch (_) {}
  }

  void setValue(int n) {
    sel = n;
    _send({'t': 'set', 'v': n});
    _n();
  }

  void clearValue() {
    sel = null;
    _send({'t': 'clear'});
    _n();
  }

  void disconnect() {
    final s = _s;
    _s = null;
    connected = false;
    color = -1;
    name = '';
    phase = 'idle';
    players = 0;
    sel = null;
    message = '';
    try {
      s?.destroy();
    } catch (_) {}
    _n();
  }
}

// ---------------------------------------------------------------------
//  UI
// ---------------------------------------------------------------------
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ControllerApp());
}

class ControllerApp extends StatelessWidget {
  const ControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ludo Controller',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF6C4DFF),
      ),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final Conn conn = Conn();
  final TextEditingController ipCtl = TextEditingController();
  bool manual = false;

  @override
  void dispose() {
    ipCtl.dispose();
    conn.dispose();
    super.dispose();
  }

  Widget _connectView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sports_esports, size: 90, color: Colors.white70),
            const SizedBox(height: 12),
            const Text(
              'LUDO CONTROLLER',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 3),
            ),
            const SizedBox(height: 8),
            const Text(
              'Open the Ludo Game on the other phone,\nthen tap Connect.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFC107),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              ),
              onPressed: conn.busy ? null : conn.autoConnect,
              child: conn.busy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : const Text(
                      'CONNECT',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 3),
                    ),
            ),
            if (conn.message.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(
                conn.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.amberAccent),
              ),
            ],
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => setState(() => manual = !manual),
              child: Text(manual ? 'Hide manual address' : 'Type the game address instead'),
            ),
            if (manual) ...[
              TextField(
                controller: ipCtl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Game phone address',
                  hintText: '192.168.1.5',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: conn.busy
                    ? null
                    : () {
                        final t = ipCtl.text.trim();
                        if (t.isNotEmpty) conn.connect(t);
                      },
                child: const Text('Connect to this address'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _hint() {
    switch (conn.phase) {
      case 'roll':
        return 'Waiting for the dice — pick a number now';
      case 'rolling':
        return 'Dice is rolling...';
      case 'move':
        return 'Choosing a token to move';
      case 'over':
        return 'Game over';
      default:
        return 'Game not started yet';
    }
  }

  Widget _numButton(int n) {
    final selected = conn.sel == n;
    final base = conn.color >= 0 ? kColors[conn.color] : const Color(0xFF5B5B8A);
    final darkText = selected && conn.color == 2;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        conn.setValue(n);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: selected ? base : const Color(0xFF26264A),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 4 : 1.5,
          ),
        ),
        child: Center(
          child: Text(
            '$n',
            style: TextStyle(
              fontSize: 64,
              fontWeight: FontWeight.w900,
              color: darkText ? Colors.black87 : Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _controlView() {
    final hasTurn = conn.color >= 0;
    final bannerColor = hasTurn ? kColors[conn.color] : const Color(0xFF3A3A5E);
    final bannerText = hasTurn ? conn.name.toUpperCase() : 'WAITING';
    final textColor = hasTurn && conn.color == 2 ? Colors.black87 : Colors.white;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B5E20),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text('● Connected', style: TextStyle(fontSize: 13)),
              ),
              const Spacer(),
              TextButton(onPressed: conn.disconnect, child: const Text('Disconnect')),
            ],
          ),
          const SizedBox(height: 10),
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 20),
            decoration: BoxDecoration(
              color: bannerColor,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                Text(
                  conn.players > 0 ? 'ROLLING NOW  ·  ${conn.players}-PLAYER GAME' : 'ROLLING NOW',
                  style: TextStyle(
                    color: textColor.withAlpha(190),
                    fontSize: 12,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  bannerText,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 46,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4,
                  ),
                ),
                Text(_hint(), style: TextStyle(color: textColor.withAlpha(220), fontSize: 14)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              physics: const NeverScrollableScrollPhysics(),
              children: [for (var n = 1; n <= 6; n++) _numButton(n)],
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: conn.sel == null ? null : conn.clearValue,
              child: Text(
                conn.sel == null
                    ? 'Next roll: random'
                    : 'Next roll: ${conn.sel}  —  tap to go back to random',
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12122A),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: conn,
          builder: (context, _) => conn.connected ? _controlView() : _connectView(),
        ),
      ),
    );
  }
}
