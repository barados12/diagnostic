// lib/main.dart
// CarDiagnosticAI - All-in-one production-ready code
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

// ============================================================
// 1. MODELS
// ============================================================

class VehicleData {
  final double rpm;
  final double speed;
  final double coolantTemp;
  final double engineLoad;
  final double intakeTemp;
  final double mafFlow;
  final double fuelTrim;
  final DateTime timestamp;
  final double odometer;
  VehicleData({
    required this.rpm,
    required this.speed,
    required this.coolantTemp,
    required this.engineLoad,
    required this.intakeTemp,
    required this.mafFlow,
    required this.fuelTrim,
    required this.timestamp,
    required this.odometer,
  });
  Map<String, dynamic> toMap() => {
    'rpm': rpm,
    'speed': speed,
    'coolantTemp': coolantTemp,
    'engineLoad': engineLoad,
    'intakeTemp': intakeTemp,
    'mafFlow': mafFlow,
    'fuelTrim': fuelTrim,
    'timestamp': timestamp.toIso8601String(),
    'odometer': odometer,
  };
  double get healthScore {
    double score = 100;
    if (coolantTemp > 105) score -= 30;
    else if (coolantTemp > 95) score -= 15;
    if (engineLoad > 85) score -= 20;
    if (rpm > 5500) score -= 15;
    if (fuelTrim.abs() > 12) score -= 25;
    return score.clamp(0, 100).toDouble();
  }
}

class PartLifespan {
  final String partName;
  double remainingPercent;
  final double initialLifespanKm;
  double currentUsageKm;
  DateTime lastReplaced;
  PartLifespan({
    required this.partName,
    required this.remainingPercent,
    required this.initialLifespanKm,
    required this.currentUsageKm,
    required this.lastReplaced,
  });
  double get remainingKm => (initialLifespanKm - currentUsageKm).clamp(0, initialLifespanKm);
}

// ============================================================
// 2. DATABASE SERVICE
// ============================================================

class DatabaseService {
  static Database? _db;
  static final instance = DatabaseService._();
  DatabaseService._();
  Future<Database> get database async => _db ??= await _initDB();
  Future<Database> _initDB() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/car_diagnostic.db';
    return await openDatabase(path, version: 2, onCreate: _onCreate, onUpgrade: _onUpgrade);
  }
  void _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE vehicle_data(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        rpm REAL, speed REAL, coolantTemp REAL, engineLoad REAL,
        intakeTemp REAL, mafFlow REAL, fuelTrim REAL, timestamp TEXT, odometer REAL
      )
    ''');
    await db.execute(''CREATE TABLE dtc_codes(id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT, description TEXT, severity TEXT, timestamp TEXT)');
    await db.execute('''
      CREATE TABLE parts_lifespan(
        partName TEXT PRIMARY KEY, remainingPercent REAL, currentUsageKm REAL, lastReplaced TEXT, initialLifespanKm REAL
      )
    ''');
  }
  void _onUpgrade(Database db, int old, int new) async {
    if (old < 2) await db.execute('ALTER TABLE vehicle_data ADD COLUMN odometer REAL DEFAULT 0');
  }
  Future<void> insertVehicleData(VehicleData data) async {
    final db = await database;
    await db.insert('vehicle_data', data.toMap());
  }
  Future<List<VehicleData>> getHistoricalData({int limit = 200}) async {
    final db = await database;
    final maps = await db.query('vehicle_data', orderBy: 'timestamp DESC', limit: limit);
    return maps.map((m) => VehicleData(
      rpm: m['rpm'] as double, speed: m['speed'] as double, coolantTemp: m['coolantTemp'] as double,
      engineLoad: m['engineLoad'] as double, intakeTemp: m['intakeTemp'] as double? ?? 0,
      mafFlow: m['mafFlow'] as double? ?? 0, fuelTrim: m['fuelTrim'] as double? ?? 0,
      timestamp: DateTime.parse(m['timestamp'] as String), odometer: m['odometer'] as double? ?? 0,
    )).toList();
  }
  Future<void> insertDTCCode(String code, String description, String severity) async {
    final db = await database;
    await db.insert('dtc_codes', {'code': code, 'description': description, 'severity': severity, 'timestamp': DateTime.now().toIso8601String()});
  }
  Future<List<Map<String,dynamic>>> getDTCHistory() async {
    final db = await database;
    return await db.query('dtc_codes', orderBy: 'timestamp DESC');
  }
  Future<Map<String,PartLifespan>> loadPartsLifespan() async {
    final db = await database;
    final result = await db.query('parts_lifespan');
    Map<String,PartLifespan> parts = {};
    for (var row in result) {
      parts[row['partName'] as String] = PartLifespan(
        partName: row['partName'] as String,
        remainingPercent: row['remainingPercent'] as double,
        initialLifespanKm: row['initialLifespanKm'] as double,
        currentUsageKm: row['currentUsageKm'] as double,
        lastReplaced: DateTime.parse(row['lastReplaced'] as String),
      );
    }
    if (parts.isEmpty) {
      final defaultParts = {
        'زيت المحرك': PartLifespan(partName: 'زيت المحرك', remainingPercent: 100, initialLifespanKm: 8000, currentUsageKm: 0, lastReplaced: DateTime.now()),
        'شمعات الاحتراق': PartLifespan(partName: 'شمعات الاحتراق', remainingPercent: 100, initialLifespanKm: 40000, currentUsageKm: 0, lastReplaced: DateTime.now()),
        'فلتر الهواء': PartLifespan(partName: 'فلتر الهواء', remainingPercent: 100, initialLifespanKm: 20000, currentUsageKm: 0, lastReplaced: DateTime.now()),
        'حساس الأكسجين': PartLifespan(partName: 'حساس الأكسجين', remainingPercent: 100, initialLifespanKm: 100000, currentUsageKm: 0, lastReplaced: DateTime.now()),
      };
      await savePartsLifespan(defaultParts);
      return defaultParts;
    }
    return parts;
  }
  Future<void> savePartsLifespan(Map<String,PartLifespan> parts) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('parts_lifespan');
      for (var part in parts.values) {
        await txn.insert('parts_lifespan', {
          'partName': part.partName,
          'remainingPercent': part.remainingPercent,
          'currentUsageKm': part.currentUsageKm,
          'lastReplaced': part.lastReplaced.toIso8601String(),
          'initialLifespanKm': part.initialLifespanKm,
        });
      }
    });
  }
  Future<double> getLatestOdometer() async {
    final db = await database;
    final result = await db.query('vehicle_data', orderBy: 'timestamp DESC', limit: 1);
    if (result.isNotEmpty) return result.first['odometer'] as double? ?? 0;
    return 0;
  }
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('vehicle_data');
    await db.delete('dtc_codes');
    await db.delete('parts_lifespan');
  }
}

// ============================================================
// 3. OBD SERVICE (Bluetooth)
// ============================================================

class OBDService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  bool _connected = false;
  double _odometer = 0;
  DateTime? _lastTimestamp;
  double? _lastSpeed;
  bool get isConnected => _connected;
  Stream<List<BluetoothDevice>> scanDevices() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
    return FlutterBluePlus.scanResults;
  }
  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect();
      _device = device;
      _connected = true;
      await _discoverServices();
      _odometer = await DatabaseService.instance.getLatestOdometer();
    } catch(e) { throw Exception('فشل الاتصال: $e'); }
  }
  Future<void> _discoverServices() async {
    final services = await _device!.discoverServices();
    for (var service in services) {
      for (var char in service.characteristics) {
        if (char.uuid.toString().toLowerCase().contains('ff01') || char.uuid.toString().toLowerCase().contains('fff1')) {
          _characteristic = char;
          break;
        }
      }
    }
  }
  Future<String> sendCommand(String cmd) async {
    if (_characteristic == null) return '';
    try {
      await _characteristic!.write(Uint8List.fromList(cmd.codeUnits));
      await Future.delayed(const Duration(milliseconds: 100));
      final response = await _characteristic!.read();
      return String.fromCharCodes(response);
    } catch(e) { return ''; }
  }
  double _parsePID(String response) {
    if (response.length < 10) return 0;
    try {
      final hex = response.substring(6,10);
      return int.parse(hex, radix: 16).toDouble();
    } catch(e) { return 0; }
  }
  double _parseOdometer(String response) {
    if (response.length < 14) return 0;
    try {
      final hex = response.substring(6,14);
      return int.parse(hex, radix: 16) / 1000.0;
    } catch(e) { return 0; }
  }
  Future<VehicleData?> readCurrentData() async {
    if (!_connected) return null;
    try {
      final rpmRaw = await sendCommand('010C\r');
      final speedRaw = await sendCommand('010D\r');
      final tempRaw = await sendCommand('0105\r');
      final loadRaw = await sendCommand('0104\r');
      final odomRaw = await sendCommand('0126\r');
      final rpm = _parsePID(rpmRaw) * 0.25;
      final speed = _parsePID(speedRaw);
      final coolant = _parsePID(tempRaw) - 40;
      final load = _parsePID(loadRaw) * 100 / 255;
      double odom = _parseOdometer(odomRaw);
      final now = DateTime.now();
      if (_lastTimestamp != null && _lastSpeed != null) {
        final hours = now.difference(_lastTimestamp!).inSeconds / 3600.0;
        final avgSpeed = (_lastSpeed! + speed) / 2;
        final deltaKm = avgSpeed * hours;
        if (deltaKm > 0 && deltaKm < 5) _odometer += deltaKm;
      }
      _lastTimestamp = now;
      _lastSpeed = speed;
      if (odom > 0) _odometer = odom;
      return VehicleData(
        rpm: rpm, speed: speed, coolantTemp: coolant, engineLoad: load,
        intakeTemp: 0, mafFlow: 0, fuelTrim: 0, timestamp: now, odometer: _odometer,
      );
    } catch(e) { return null; }
  }
  Future<void> disconnect() async {
    if (_device != null) await _device!.disconnect();
    _connected = false;
  }
}

// ============================================================
// 4. GEMINI AI SERVICE (Secure via dart-define)
// ============================================================

class GeminiService {
  late final GenerativeModel _model;
  bool _available = true;
  GeminiService() {
    final apiKey = const String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
    if (apiKey.isEmpty) {
      print('⚠️ Gemini API key missing. AI features disabled.');
      _available = false;
    } else {
      _model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: apiKey);
    }
  }
  Future<String> analyzeDTC(String dtcCode, VehicleData? currentData) async {
    if (!_available) return 'ميزة الذكاء الاصطناعي غير متاحة (مفتاح API مفقود).';
    final prompt = 'أنت خبير سيارات. حلل رمز العطل $dtcCode. البيانات: ${currentData?.toMap() ?? "غير متاحة"}. قدم شرح، أسباب، إصلاح، خطورة، نصائح. بالعربية.';
    try {
      final response = await _model.generateContent([Content.text(prompt)]);
      return response.text ?? 'لا يوجد تحليل.';
    } catch(e) { return 'خطأ: $e'; }
  }
  Future<String> predictAnomalies(List<VehicleData> history) async {
    if (!_available) return 'التنبؤ غير متاح.';
    if (history.isEmpty) return 'لا توجد بيانات.';
    final recent = history.take(20).map((d) => "RPM:${d.rpm}, Temp:${d.coolantTemp}, Load:${d.engineLoad}").join('\n');
    final prompt = 'بناءً على البيانات التالية:\n$recent\nهل توجد علامات مبكرة لأعطال وشيكة؟ قدم تنبيهاً.';
    try {
      final response = await _model.generateContent([Content.text(prompt)]);
      return response.text ?? 'لا شذوذ.';
    } catch(e) { return 'خطأ في التنبؤ.'; }
  }
  Future<String> generateHealthReport(List<VehicleData> history, Map<String,PartLifespan> parts) async {
    if (!_available) return 'التقرير غير متاح.';
    final partsSummary = parts.values.map((p) => "${p.partName}: ${p.remainingPercent.toStringAsFixed(0)}%").join(', ');
    final prompt = 'تقرير صحي: ${history.length} قراءة، عمر القطع: $partsSummary. قدم ملخصاً وتوصيات.';
    try {
      final response = await _model.generateContent([Content.text(prompt)]);
      return response.text ?? 'تقرير مؤقت: حالة مقبولة.';
    } catch(e) { return 'خطأ في التقرير.'; }
  }
}

// ============================================================
// 5. MAIN APP & SCREENS
// ============================================================

void main() => runApp(const CarDiagnosticApp());

class CarDiagnosticApp extends StatelessWidget {
  const CarDiagnosticApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CarDiagnosticAI Pro',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.cyan[800],
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(backgroundColor: Colors.black, elevation: 0),
      ),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  final OBDService _obd = OBDService();
  static const List<Widget> _screens = [DashboardScreen(), DiagnosticsScreen(), PartsLifespanScreen(), HealthReportScreen()];
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.speed), label: 'القيادة'),
          NavigationDestination(icon: Icon(Icons.bug_report), label: 'الأعطال'),
          NavigationDestination(icon: Icon(Icons.build), label: 'عمر القطع'),
          NavigationDestination(icon: Icon(Icons.health_and_safety), label: 'التقرير'),
        ],
      ),
      floatingActionButton: _selectedIndex == 0
          ? FloatingActionButton(
              onPressed: () async {
                if (!_obd.isConnected) {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectionScreen()));
                  setState(() {});
                } else {
                  await _obd.disconnect();
                  setState(() {});
                }
              },
              backgroundColor: _obd.isConnected ? Colors.red : Colors.cyan,
              child: Icon(_obd.isConnected ? Icons.bluetooth_disabled : Icons.bluetooth),
            )
          : null,
    );
  }
}

// ---------- Connection Screen ----------
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}
class _ConnectionScreenState extends State<ConnectionScreen> {
  final OBDService _obd = OBDService();
  List<BluetoothDevice> _devices = [];
  bool _scanning = false;
  @override
  void initState() { super.initState(); _startScan(); }
  Future<void> _startScan() async {
    setState(() { _scanning = true; _devices.clear(); });
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    FlutterBluePlus.scanResults.listen((results) {
      setState(() { _devices = results.map((r) => r.device).toList(); });
    });
    await FlutterBluePlus.stopScan();
    setState(() { _scanning = false; });
  }
  Future<void> _connect(BluetoothDevice device) async {
    try {
      await _obd.connectToDevice(device);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الاتصال')));
        Navigator.pop(context);
      }
    } catch(e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل: $e'))); }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('اتصال OBD-II'), backgroundColor: Colors.cyan[900]),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: _startScan,
              icon: Icon(_scanning ? Icons.stop : Icons.refresh),
              label: Text(_scanning ? 'جاري البحث...' : 'بحث عن أجهزة'),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _devices.length,
              itemBuilder: (_, i) => ListTile(
                leading: const Icon(Icons.bluetooth, color: Colors.blue),
                title: Text(_devices[i].name.isNotEmpty ? _devices[i].name : 'جهاز OBD'),
                subtitle: Text(_devices[i].remoteId.toString()),
                onTap: () => _connect(_devices[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Dashboard Screen (Live + Alerts) ----------
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}
class _DashboardScreenState extends State<DashboardScreen> {
  final OBDService _obd = OBDService();
  final DatabaseService _db = DatabaseService.instance;
  final GeminiService _ai = GeminiService();
  VehicleData? _current;
  List<VehicleData> _history = [];
  Timer? _timer;
  String _anomalyAlert = '';
  @override
  void initState() { super.initState(); _startLiveUpdates(); }
  void _startLiveUpdates() {
    _timer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_obd.isConnected) {
        final data = await _obd.readCurrentData();
        if (data != null) {
          setState(() {
            _current = data;
            _history.insert(0, data);
            if (_history.length > 100) _history.removeLast();
          });
          await _db.insertVehicleData(data);
          await _checkAnomalies(data);
          await _updatePartsLifespan(data.odometer);
        }
      }
    });
  }
  Future<void> _updatePartsLifespan(double odometer) async {
    final parts = await _db.loadPartsLifespan();
    bool changed = false;
    for (var part in parts.values) {
      if (odometer > part.currentUsageKm) {
        part.currentUsageKm = odometer;
        part.remainingPercent = ((part.initialLifespanKm - part.currentUsageKm) / part.initialLifespanKm * 100).clamp(0, 100);
        changed = true;
      }
    }
    if (changed) await _db.savePartsLifespan(parts);
  }
  Future<void> _checkAnomalies(VehicleData data) async {
    String alert = '';
    if (data.coolantTemp > 105) alert = '⚠️ حرارة المحرك مرتفعة جداً! أوقف السيارة.';
    else if (data.coolantTemp > 95) alert = '⚠️ ارتفاع حرارة المحرك.';
    else if (data.rpm > 5500) alert = '⚠️ RPM عالية جداً.';
    else if (data.engineLoad > 85 && data.speed < 40) alert = '⚠️ حمل المحرك مرتفع مع سرعة منخفضة.';
    if (alert.isNotEmpty && alert != _anomalyAlert) {
      setState(() => _anomalyAlert = alert);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(alert), backgroundColor: Colors.red));
      await _db.insertDTCCode('PRED-001', alert, 'مرتفع');
    } else if (alert.isEmpty && _anomalyAlert.isNotEmpty) {
      setState(() => _anomalyAlert = '');
    }
  }
  @override
  void dispose() { _timer?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (!_obd.isConnected) {
      return const Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [Icon(Icons.bluetooth_disabled, size: 80, color: Colors.grey), SizedBox(height: 20), Text('غير متصل', style: TextStyle(fontSize: 18))],
      ));
    }
    if (_current == null) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (_anomalyAlert.isNotEmpty) Container(padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: Colors.red[900], borderRadius: BorderRadius.circular(12)), child: Text(_anomalyAlert, style: const TextStyle(fontWeight: FontWeight.bold))),
          Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.cyan[900]!, Colors.cyan[800]!]), borderRadius: BorderRadius.circular(20)), child: Column(children: [const Text('صحة المحرك'), Text('${_current!.healthScore.toInt()}%', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold)), LinearProgressIndicator(value: _current!.healthScore/100, backgroundColor: Colors.white24, valueColor: const AlwaysStoppedAnimation(Colors.white))])),
          const SizedBox(height: 20),
          Row(children: [_gaugeCard('RPM', _current!.rpm, 0, 8000, ''), _gaugeCard('السرعة', _current!.speed, 0, 200, 'كم/س')]),
          const SizedBox(height: 20),
          Row(children: [_gaugeCard('حرارة', _current!.coolantTemp, 0, 130, '°C', warning: 100), _gaugeCard('حمل المحرك', _current!.engineLoad, 0, 100, '%')]),
          const SizedBox(height: 20),
          Text('المسافة المقطوعة: ${_current!.odometer.toStringAsFixed(1)} كم'),
          const SizedBox(height: 10),
          Container(height: 150, padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(16)), child: LineChart(LineChartData(gridData: const FlGridData(show: true), titlesData: const FlTitlesData(show: false), borderData: FlBorderData(show: false), minX: 0, maxX: _history.length.toDouble(), minY: 0, maxY: 8000, lineBarsData: [LineChartBarData(spots: _history.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value.rpm)).toList(), isCurved: true, color: Colors.cyan, barWidth: 2, dotData: const FlDotData(show: false))]))),
        ],
      ),
    );
  }
  Widget _gaugeCard(String title, double value, double min, double max, String unit, {double? warning}) {
    final percent = ((value - min) / (max - min)).clamp(0, 1);
    Color color = Colors.green;
    if (warning != null && value > warning) color = Colors.red;
    else if (percent > 0.8) color = Colors.orange;
    return Expanded(
      child: Container(margin: const EdgeInsets.symmetric(horizontal: 4), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(16)), child: Column(children: [Text(title, style: const TextStyle(fontSize: 14, color: Colors.white70)), const SizedBox(height: 8), Stack(alignment: Alignment.center, children: [SizedBox(height: 70, width: 70, child: CircularProgressIndicator(value: percent, strokeWidth: 6, backgroundColor: Colors.grey[700], valueColor: AlwaysStoppedAnimation(color))), Column(children: [Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), Text(unit, style: const TextStyle(fontSize: 10))])])])),
    );
  }
}

// ---------- Diagnostics Screen (DTC) ----------
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});
  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}
class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final OBDService _obd = OBDService();
  final GeminiService _ai = GeminiService();
  final DatabaseService _db = DatabaseService.instance;
  List<String> _dtcCodes = [];
  bool _scanning = false;
  Map<String,String> _analysis = {};
  Future<void> _scanDTC() async {
    if (!_obd.isConnected) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى الاتصال بالسيارة'))); return; }
    setState(() { _scanning = true; _dtcCodes.clear(); _analysis.clear(); });
    final response = await _obd.sendCommand('03\r');
    List<String> codes = _parseDTCCodes(response);
    if (codes.isEmpty) codes = ['لا توجد رموز أعطال'];
    setState(() => _dtcCodes = codes);
    for (var code in codes) {
      if (code != 'لا توجد رموز أعطال') {
        final analysis = await _ai.analyzeDTC(code, null);
        setState(() => _analysis[code] = analysis);
        await _db.insertDTCCode(code, analysis.length > 200 ? analysis.substring(0,200) : analysis, 'متوسط');
      }
    }
    setState(() => _scanning = false);
  }
  List<String> _parseDTCCodes(String resp) {
    List<String> list = [];
    if (resp.contains('43') && resp.length > 10) {
      final hex = resp.substring(6);
      for (int i=0; i+4 <= hex.length; i+=4) {
        final codeHex = hex.substring(i, i+4);
        if (codeHex != '0000') list.add(_hexToDTC(codeHex));
      }
    }
    return list;
  }
  String _hexToDTC(String hex) {
    const map = {'0':'P0','1':'P1','2':'P2','3':'P3','4':'C0','5':'C1','6':'C2','7':'C3','8':'B0','9':'B1','A':'B2','B':'B3','C':'U0','D':'U1','E':'U2','F':'U3'};
    return '${map[hex[0]] ?? 'P'}${hex.substring(1)}';
  }
  Future<void> _clearDTC() async {
    if (!_obd.isConnected) return;
    await _obd.sendCommand('04\r');
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم مسح الرموز')));
    setState(() => _dtcCodes.clear());
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تشخيص الأعطال'), backgroundColor: Colors.cyan[900], actions: [IconButton(onPressed: _scanDTC, icon: Icon(_scanning ? Icons.hourglass_empty : Icons.search)), IconButton(onPressed: _clearDTC, icon: const Icon(Icons.cleaning_services))]),
      body: _scanning ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircularProgressIndicator(), Text('جاري الفحص...')])) : ListView.builder(itemCount: _dtcCodes.length, itemBuilder: (_, i) => Card(margin: const EdgeInsets.all(8), child: ExpansionTile(leading: const Icon(Icons.error, color: Colors.red), title: Text(_dtcCodes[i], style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: _analysis[_dtcCodes[i]] != null ? Text(_analysis[_dtcCodes[i]]!.substring(0, min(80, _analysis[_dtcCodes[i]]!.length)) + '...') : const Text('اضغط للتحليل'), children: [Padding(padding: const EdgeInsets.all(16), child: Text(_analysis[_dtcCodes[i]] ?? 'جاري التحليل...', style: const TextStyle(height: 1.4)))])),),
    );
  }
}

// ---------- Parts Lifespan Screen ----------
class PartsLifespanScreen extends StatefulWidget {
  const PartsLifespanScreen({super.key});
  @override
  State<PartsLifespanScreen> createState() => _PartsLifespanScreenState();
}
class _PartsLifespanScreenState extends State<PartsLifespanScreen> {
  final DatabaseService _db = DatabaseService.instance;
  Map<String,PartLifespan> _parts = {};
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async { final parts = await _db.loadPartsLifespan(); setState(() => _parts = parts); }
  Future<void> _reset(PartLifespan part) async {
    final newDate = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now());
    if (newDate != null) {
      setState(() {
        part.currentUsageKm = 0;
        part.remainingPercent = 100;
        part.lastReplaced = newDate;
      });
      await _db.savePartsLifespan(_parts);
    }
  }
  @override
  Widget build(BuildContext context) {
    if (_parts.isEmpty) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      appBar: AppBar(title: const Text('عمر القطع'), backgroundColor: Colors.cyan[900]),
      body: ListView.builder(itemCount: _parts.length, itemBuilder: (_, i) {
        final part = _parts.values.elementAt(i);
        return Card(margin: const EdgeInsets.all(10), child: ListTile(
          leading: const Icon(Icons.build, color: Colors.orange),
          title: Text(part.partName, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('المتبقي: ${part.remainingPercent.toStringAsFixed(0)}% (${part.remainingKm.toStringAsFixed(0)} كم)'), LinearProgressIndicator(value: part.remainingPercent/100, backgroundColor: Colors.grey[700], valueColor: const AlwaysStoppedAnimation(Colors.green))]),
          trailing: part.remainingPercent < 20 ? const Icon(Icons.warning, color: Colors.red) : null,
          onTap: () => _reset(part),
        ));
      }),
    );
  }
}

// ---------- Health Report + SOS Screen ----------
class HealthReportScreen extends StatefulWidget {
  const HealthReportScreen({super.key});
  @override
  State<HealthReportScreen> createState() => _HealthReportScreenState();
}
class _HealthReportScreenState extends State<HealthReportScreen> {
  final DatabaseService _db = DatabaseService.instance;
  final GeminiService _ai = GeminiService();
  final OBDService _obd = OBDService();
  String _report = '';
  bool _loading = false;
  Position? _position;
  String _address = 'جاري تحديد الموقع...';
  @override
  void initState() { super.initState(); _getLocation(); }
  Future<void> _getLocation() async {
    if (await Permission.location.request().isGranted) {
      try {
        final pos = await Geolocator.getCurrentPosition();
        setState(() => _position = pos);
        final marks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (marks.isNotEmpty) setState(() => _address = '${marks.first.street}, ${marks.first.locality}');
      } catch(e) {}
    }
  }
  Future<void> _generateReport() async {
    setState(() { _loading = true; _report = ''; });
    final history = await _db.getHistoricalData(limit: 100);
    final parts = await _db.loadPartsLifespan();
    final report = await _ai.generateHealthReport(history, parts);
    setState(() { _report = report; _loading = false; });
  }
  Future<void> _sendSOS() async {
    if (_position == null) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الموقع غير متاح'))); return; }
    final msg = '🚨 SOS من CarDiagnosticAI Pro\nالموقع: $_address\nالإحداثيات: ${_position!.latitude}, ${_position!.longitude}\nالوقت: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now())}';
    final uri = Uri(scheme: 'sms', path: '', queryParameters: {'body': msg});
    if (await canLaunchUrl(uri)) await launchUrl(uri);
    else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح تطبيق الرسائل')));
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('التقرير الصحي والطوارئ'), backgroundColor: Colors.cyan[900]),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ElevatedButton.icon(onPressed: _generateReport, icon: const Icon(Icons.auto_awesome), label: const Text('توليد تقرير صحي'), style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50))),
            const SizedBox(height: 20),
            if (_loading) const CircularProgressIndicator(),
            if (_report.isNotEmpty) Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(16)), child: Text(_report, style: const TextStyle(height: 1.5))),
            const SizedBox(height: 20),
            Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.red[900], borderRadius: BorderRadius.circular(16)), child: Column(children: [const Text('حالة الطوارئ', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 8), Text(_address), const SizedBox(height: 12), Row(children: [Expanded(child: ElevatedButton.icon(onPressed: _sendSOS, icon: const Icon(Icons.sos), label: const Text('إرسال SOS'), style: ElevatedButton.styleFrom(backgroundColor: Colors.red))), const SizedBox(width: 10), Expanded(child: ElevatedButton.icon(onPressed: () async { if (_position != null) { final url = 'https://www.google.com/maps/search/?api=1&query=${_position!.latitude},${_position!.longitude}'; if (await canLaunchUrl(Uri.parse(url))) await launchUrl(Uri.parse(url)); } }, icon: const Icon(Icons.map), label: const Text('فتح الخريطة')))])])),
          ],
        ),
      ),
    );
  }
}
