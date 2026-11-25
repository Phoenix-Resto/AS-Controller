import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

void main() => runApp(const AsControllerApp());

class AsControllerApp extends StatelessWidget {
  const AsControllerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AS Controller',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB),
              brightness: Brightness.dark),
          useMaterial3: true,
        ),
        home: const ControllerPage(),
      );
}

class ControllerPage extends StatefulWidget {
  const ControllerPage({super.key});
  @override
  State<ControllerPage> createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage>
    with WidgetsBindingObserver {
  final ip = TextEditingController();
  final pin = TextEditingController();
  final deviceName = TextEditingController(text: 'Phone');
  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;
  bool connected = false;
  bool connecting = false;
  String message = 'Not connected';
  Map<String, String> mappings = {};
  List<dynamic> assignments = [];
  List<String> availableKeys = [];
  final Set<String> held = {};

  // Stable identifiers; any control can be assigned any unused key.
  static const controls = <String, String>{
    'up': '↑', 'left': '←', 'down': '↓', 'right': '→',
    'a': 'A', 'b': 'B', 'x': 'X', 'y': 'Y',
    'l1': 'L1', 'r1': 'R1', 'start': 'Start', 'select': 'Select',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) releaseAll();
  }

  void send(Map<String, Object?> payload) {
    if (socket?.readyState == WebSocket.open) {
      socket!.add(jsonEncode(payload));
    }
  }

  void releaseAll() {
    held.clear();
    send({'type': 'release_all'});
  }

  Future<void> connect() async {
    if (connecting) return;
    if (ip.text.trim().isEmpty || pin.text.trim().isEmpty) {
      setState(() => message = 'Enter the Windows PC IP and pairing PIN');
      return;
    }
    await disconnect();
    setState(() {
      connecting = true;
      message = 'Connecting…';
    });
    WebSocket? candidate;
    try {
      candidate = await WebSocket.connect(
        'ws://${ip.text.trim()}:8765',
      ).timeout(const Duration(seconds: 8));
      socket = candidate;
      subscription = candidate.listen((data) {
        try {
          final event = jsonDecode(data as String) as Map<String, dynamic>;
          if (!mounted) return;
          setState(() {
            switch (event['type']) {
              case 'welcome':
                connected = true;
                message = 'Connected — choose your keyboard mappings';
                availableKeys = List<String>.from(event['keys'] as List);
              case 'state':
                mappings = Map<String, String>.from(event['mappings'] as Map);
                assignments = List<dynamic>.from(event['assignments'] as List);
              case 'error':
                message = event['message']?.toString() ?? 'Host error';
            }
          });
        } catch (_) {
          if (mounted) setState(() => message = 'Unexpected host message');
        }
      }, onError: (Object error) => markDisconnected('$error'),
          onDone: () => markDisconnected('Connection closed'));
      send({'type': 'hello', 'pin': pin.text.trim(),
        'name': deviceName.text.trim()});
    } catch (error) {
      await candidate?.close();
      if (mounted) setState(() => message = 'Could not connect: $error');
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  void markDisconnected(String reason) {
    held.clear();
    if (!mounted) return;
    setState(() {
      connected = false;
      socket = null;
      mappings = {};
      assignments = [];
      message = reason;
    });
  }

  Future<void> disconnect() async {
    releaseAll();
    await subscription?.cancel();
    subscription = null;
    await socket?.close();
    socket = null;
    if (mounted) {
      setState(() {
        connected = false;
        mappings = {};
        assignments = [];
      });
    }
  }

  void press(String control) {
    if (!connected || !mappings.containsKey(control) || !held.add(control)) return;
    setState(() {});
    send({'type': 'down', 'control': control});
  }

  void release(String control) {
    if (!held.remove(control)) return;
    if (mounted) setState(() {});
    send({'type': 'up', 'control': control});
  }

  Future<void> editMapping(String control) async {
    if (!connected) return;
    final current = mappings[control];
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.72,
          child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Map ${controls[control]}',
                style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            Flexible(child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(title: const Text('Unassign key'),
                    selected: current == null,
                    onTap: () => Navigator.pop(ctx, '')),
                ...availableKeys.map((key) {
                  final owner = assignments.cast<Map>().where(
                      (item) => item['key'] == key).toList();
                  final occupied = owner.isNotEmpty && current != key;
                  return ListTile(
                    title: Text(key),
                    subtitle: occupied ? Text('Already assigned: '
                        '${owner.first['device']} / ${owner.first['control']}') : null,
                    enabled: !occupied,
                    selected: current == key,
                    onTap: occupied ? null : () => Navigator.pop(ctx, key),
                  );
                }),
              ],
            )),
          ]),
          ),
        ),
      ),
    );
    if (selected == null) return;
    release(control);
    send({'type': 'assign', 'control': control, 'key': selected});
  }

  Widget control(String id, {bool expanded = false}) {
    final mapped = mappings[id];
    return Expanded(
      flex: expanded ? 2 : 1,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => press(id),
          onPointerUp: (_) => release(id),
          onPointerCancel: (_) => release(id),
          child: GestureDetector(
            onLongPress: () { release(id); editMapping(id); },
            child: Container(
              decoration: BoxDecoration(
                color: held.contains(id)
                    ? const Color(0xFF2563EB) : const Color(0xFF243247),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: mapped == null
                    ? Colors.orange.shade300 : Colors.blueGrey),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Column(mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FittedBox(child: Text(controls[id]!,
                      style: const TextStyle(fontSize: 22,
                          fontWeight: FontWeight.bold))),
                  Text(mapped ?? 'Unmapped', textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget controlRow(List<String> ids) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: ids.map((id) => control(id)).toList(),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AS Controller · Keyboard Mode'), actions: [
      if (connected) TextButton(onPressed: disconnect,
          child: const Text('Disconnect')),
    ]),
    body: SafeArea(child: LayoutBuilder(builder: (ctx, constraints) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!connected) ...[
              TextField(controller: ip,
                decoration: const InputDecoration(labelText: 'Windows PC IPv4 address',
                    hintText: '192.168.1.100')),
              TextField(controller: pin,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '6-digit host pairing PIN')),
              TextField(controller: deviceName,
                decoration: const InputDecoration(labelText: 'Phone name')),
              const SizedBox(height: 12),
              FilledButton(onPressed: connecting ? null : connect,
                  child: Text(connecting ? 'Connecting…' : 'Connect to PC')),
            ],
            Padding(padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(message)),
            if (connected) ...[
              const Text('Long-press a control to assign a unique PC key.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              // Aspect ratio scales the whole pad to available display width.
              AspectRatio(aspectRatio: constraints.maxWidth > 550 ? 2.2 : 1.25,
                child: Row(children: [
                  Expanded(child: Column(children: [
                    Expanded(child: controlRow(['up'])),
                    Expanded(child: controlRow(['left', 'down', 'right'])),
                    Expanded(child: controlRow(['l1', 'select'])),
                  ])),
                  Expanded(child: Column(children: [
                    Expanded(child: controlRow(['y', 'x'])),
                    Expanded(child: controlRow(['b', 'a'])),
                    Expanded(child: controlRow(['r1', 'start'])),
                  ])),
                ]),
              ),
              const SizedBox(height: 10),
              Text('Globally reserved keys: ${assignments.length}',
                  textAlign: TextAlign.center),
            ],
          ],
        ),
      );
    })),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    releaseAll();
    subscription?.cancel();
    socket?.close();
    ip.dispose();
    pin.dispose();
    deviceName.dispose();
    super.dispose();
  }
}
