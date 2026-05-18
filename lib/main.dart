c';
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
import 'package:provider/provider.dart';

// ============================================================
// 1. النماذج (Models)
// ============================================================

class VehicleData {
  final double rpm;
  final double speed;// ============================================================
// CarDiagnosticAI Pro - النسخة المُصلحة والجاهزة للنشر
// ============================================================

import 'dart:asyn
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
    double score = 100.0;
    if (coolantTemp > 105) score -= 30;
    else if (coolantTemp > 95) score -= 15;
    if (engineLoad > 85) score -= 20;
    if (rpm > 5500) score -= 15;
    if (fuelTrim.abs() > 12) score -= 25;
    return score.clamp(0, 100);
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
// 2. خدمات قاعدة البيانات (SQLite)
// ============================================================

class DatabaseService {
  static Database? _db;
  static final DatabaseService instance = DatabaseService._();
  DatabaseService._();

  Future<<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<<Database> _initDB() async {
    Directory dir = await getApplicationDocumentsDirectory();
    String path = '${dir.path}/car_diagnostic.db';
    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE vehicle_data(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            rpm REAL,
            speed REAL,
            coolantTemp REAL,
            engineLoad REAL,
            intakeTemp REAL,
            mafFlow REAL,
            fuelTrim REAL,
            timestamp TEXT,
            odometer REAL
          )
        ''');
        await db.execute('''
          CREATE TABLE dtc_codes(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            code TEXT,
            description TEXT,
            severity TEXT,
            timestamp TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE parts_lifespan(
            partName TEXT PRIMARY KEY,
            remainingPercent REAL,
            currentUsageKm REAL,
            lastReplaced TEXT,
            initialLifespanKm REAL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE vehicle_data ADD COLUMN odometer REAL DEFAULT 0');
        }
      },
    );
  }

  Future<void> insertVehicleData(VehicleData data) async {
    try {
      final db = await database;
      await db.insert('vehicle_data', data.toMap());
    } catch (e) {
      debugPrint('DB insert error: $e');
    }
  }

  Future<List<VehicleData>> getHistoricalData({int limit = 200}) async {
    try {
      final db = await database;
      List<Map<String, dynamic>> maps = await db.query(
        'vehicle_data',
        orderBy: 'timestamp DESC',
        limit: limit,
      );
      return maps.map((m) => VehicleData(
        rpm: (m['rpm'] as num?)?.toDouble() ?? 0,
        speed: (m['speed'] as num?)?.toDouble() ?? 0,
        coolantTemp: (m['coolantTemp'] as num?)?.toDouble() ?? 0,
        engineLoad: (m['engineLoad'] as num?)?.toDouble() ?? 0,
        intakeTemp: (m['intakeTemp'] as num?)?.toDouble() ?? 0,
        mafFlow: (m['mafFlow'] as num?)?.toDouble() ?? 0,
        fuelTrim: (m['fuelTrim'] as num?)?.toDouble() ?? 0,
        timestamp: DateTime.tryParse(m['timestamp'] ?? '') ?? DateTime.now(),
        odometer: (m['odometer'] as num?)?.toDouble() ?? 0,
      )).toList();
    } catch (e) {
      debugPrint('DB read error: $e');
      return [];
    }
  }

  Future<void> insertDTCCode(String code, String description, String severity) async {
    try {
      final db = await database;
      await db.insert('dtc_codes', {
        'code': code,
        'description': description,
        'severity': severity,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('DTC insert error: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getDTCHistory() async {
    try {
      final db = await database;
      return await db.query('dtc_codes', orderBy: 'timestamp DESC');
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, PartLifespan>> loadPartsLifespan() async {
    try {
      final db = await database;
      List<Map<String, dynamic>> result = await db.query('parts_lifespan');
      Map<String, PartLifespan> parts = {};
      for (var row in result) {
        parts[row['partName']] = PartLifespan(
          partName: row['partName'],
          remainingPercent: (row['remainingPercent'] as num).toDouble(),
          initialLifespanKm: (row['initialLifespanKm'] as num).toDouble(),
          currentUsageKm: (row['currentUsageKm'] as num).toDouble(),
          lastReplaced: DateTime.tryParse(row['lastReplaced']) ?? DateTime.now(),
        );
      }
      if (parts.isEmpty) {
        parts = {
          'زيت المحرك': PartLifespan(partName: 'زيت المحرك', remainingPercent: 100, initialLifespanKm: 8000, currentUsageKm: 0, lastReplaced: DateTime.now()),
          'شمعات الاحتراق': PartLifespan(partName: 'شمعات الاحتراق', remainingPercent: 100, initialLifespanKm: 40000, currentUsageKm: 0, lastReplaced: DateTime.now()),
          'فلتر الهواء': PartLifespan(partName: 'فلتر الهواء', remainingPercent: 100, initialLifespanKm: 20000, currentUsageKm: 0, lastReplaced: DateTime.now()),
          'حساس الأكسجين': PartLifespan(partName: 'حساس الأكسجين', remainingPercent: 100, initialLifespanKm: 100000, currentUsageKm: 0, lastReplaced: DateTime.now()),
        };
        await savePartsLifespan(parts);
      }
      return parts;
    } catch (e) {
      debugPrint('Parts load error: $e');
      return {};
    }
  }

  Future<void> savePartsLifespan(Map<String, PartLifespan> parts) async {
    try {
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
    } catch (e) {
      debugPrint('Parts save error: $e');
    }
  }

  Future<double> getLatestOdometer() async {
    try {
      final db = await database;
      var result = await db.query('vehicle_data', orderBy: 'timestamp DESC', limit: 1);
      if (result.isNotEmpty) return (result.first['odometer'] as num?)?.toDouble() ?? 0;
      return 0;
    } catch (e) {
      return 0;
    }
  }

  Future<void> clearAllData() async {
    try {
      final db = await database;
      await db.delete('vehicle_data');
      await db.delete('dtc_codes');
      await db.delete('parts_lifespan');
    } catch (e) {
      debugPrint('Clear error: $e');
    }
  }
}

// ============================================================
// 3. خدمة OBD-II (Bluetooth)
// ============================================================

class OBDService extends ChangeNotifier {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  bool _connected = false;
  double _odometer = 0.0;
  DateTime? _lastTimestamp;
  double? _lastSpeed;

  bool get isConnected => _connected;
  double get odometer => _odometer;

  Stream<List<<ScanResult>> scanDevices() {
    try {
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      return FlutterBluePlus.scanResults;
    } catch (e) {
      debugPrint('Scan error: $e');
      return const Stream.empty();
    }
  }

  Future<bool> ensureBluetoothEnabled() async {
    try {
      if (await FlutterBluePlus.adapterState.first == BluetoothAdapterState.off) {
        await FlutterBluePlus.turnOn();
      }
      return true;
    } catch (e) {
      debugPrint('Bluetooth enable error: $e');
      return false;
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect(autoConnect: false, mtu: null);
      _device = device;
      _connected = true;
      notifyListeners();
      await _discoverServices();
      _odometer = await DatabaseService.instance.getLatestOdometer();
    } catch (e) {
      _connected = false;
      notifyListeners();
      throw Exception('فشل الاتصال: $e');
    }
  }

  Future<void> _discoverServices() async {
    if (_device == null) return;
    List<<BluetoothService> services = await _device!.discoverServices();
    for (var service in services) {
      for (var char in service.characteristics) {
        String uuid = char.uuid.str.toLowerCase();
        if (uuid.contains('ff01') || uuid.contains('fff1') || uuid.contains('ffe1')) {
          _characteristic = char;
          break;
        }
      }
    }
  }

  Future<String> sendCommand(String cmd) async {
    if (_characteristic == null) return '';
    try {
      await _characteristic!.write(Uint8List.fromList(cmd.codeUnits), withoutResponse: false);
      await Future.delayed(const Duration(milliseconds: 200));
      List<int> response = await _characteristic!.read();
      return String.fromCharCodes(response);
    } catch (e) {
      debugPrint('Command error: $e');
      return '';
    }
  }

  Future<VehicleData?> readCurrentData() async {
    if (!_connected || _device == null) return null;
    try {
      String rpmRaw = await sendCommand('010C\r');
      String speedRaw = await sendCommand('010D\r');
      String tempRaw = await sendCommand('0105\r');
      String loadRaw = await sendCommand('0104\r');
      String odometerRaw = await sendCommand('0126\r');

      double rpm = _parsePID(rpmRaw, 0.25);
      double speed = _parsePID(speedRaw, 1.0);
      double coolant = _parsePID(tempRaw, 1.0) - 40;
      double load = _parsePID(loadRaw, 100.0 / 255.0);
      double odometerKm = _parseOdometer(odometerRaw);

      DateTime now = DateTime.now();
      if (_lastTimestamp != null && _lastSpeed != null && speed > 0) {
        double deltaHours = now.difference(_lastTimestamp!).inSeconds / 3600.0;
        double avgSpeed = (_lastSpeed! + speed) / 2;
        double deltaKm = avgSpeed * deltaHours;
        if (deltaKm > 0 && deltaKm < 5) {
          _odometer += deltaKm;
        }
      }
      _lastTimestamp = now;
      _lastSpeed = speed;

      if (odometerKm > _odometer) {
        _odometer = odometerKm;
      }

      return VehicleData(
        rpm: rpm,
        speed: speed,
        coolantTemp: coolant,
        engineLoad: load,
        intakeTemp: 0,
        mafFlow: 0,
        fuelTrim: 0,
        timestamp: now,
        odometer: _odometer,
      );
    } catch (e) {
      debugPrint('Read data error: $e');
      return null;
    }
  }

  double _parsePID(String response, double multiplier) {
    if (response.isEmpty || response.length < 6) return 0;
    try {
      response = response.replaceAll(' ', '').replaceAll('\r', '').replaceAll('\n', '').replaceAll('>', '');
      String hex = response.substring(4, min(response.length, 8));
      int val = int.parse(hex, radix: 16);
      return val * multiplier;
    } catch (e) {
      return 0;
    }
  }

  double _parseOdometer(String response) {
    if (response.isEmpty || response.length < 10) return 0;
    try {
      response = response.replaceAll(' ', '').replaceAll('\r', '').replaceAll('\n', '').replaceAll('>', '');
      String hex = response.substring(4, min(response.length, 12));
      int kmInt = int.parse(hex, radix: 16);
      return kmInt / 1000.0;
    } catch (e) {
      return 0;
    }
  }

  Future<void> disconnect() async {
    try {
      if (_device != null) await _device!.disconnect();
    } catch (e) {
      debugPrint('Disconnect error: $e');
    } finally {
      _connected = false;
      _characteristic = null;
      notifyListeners();
    }
  }
}

// ============================================================
// 4. خدمة الذكاء الاصطناعي (Gemini)
// ============================================================

class GeminiService {
  late final GenerativeModel? _model;
  bool _available = true;

  GeminiService() {
    const apiKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
    if (apiKey.isEmpty) {
      debugPrint('⚠️ مفتاح Gemini API غير موجود. سيتم تعطيل ميزات الذكاء الاصطناعي.');
      _available = false;
    } else {
      _model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: apiKey);
    }
  }

  Future<String> analyzeDTC(String dtcCode, VehicleData? currentData) async {
    if (!_available || _model == null) return 'ميزة الذكاء الاصطناعي غير متاحة (مفتاح API مفقود).';
    final prompt = '''
أنت خبير سيارات. حلل رمز العطل $dtcCode.
البيانات: ${currentData?.toMap() ?? "غير متاحة"}
قدم:
1. شرح مبسط
2. أسباب محتملة (3)
3. خطوات إصلاح
4. مستوى الخطورة
5. نصائح وقائية
باللغة العربية.
''';
    try {
      final response = await _model!.generateContent([Content.text(prompt)]);
      return response.text ?? 'لم يتم الحصول على تحليل.';
    } catch (e) {
      return 'خطأ في الاتصال بالذكاء الاصطناعي: $e';
    }
  }

  Future<String> predictAnomalies(List<VehicleData> history) async {
    if (!_available || _model == null || history.isEmpty) return 'ميزة التنبؤ غير متاحة.';
    final recent = history.take(20).toList();
    final prompt = '''
بناءً على البيانات التالية (RPM, حرارة, حمل):
${recent.map((d) => "RPM:${d.rpm.toStringAsFixed(0)}, Temp:${d.coolantTemp.toStringAsFixed(0)}, Load:${d.engineLoad.toStringAsFixed(0)}").join('\n')}
هل توجد علامات مبكرة لأعطال وشيكة؟ قدم تنبيهاً للسائق.
''';
    try {
      final response = await _model!.generateContent([Content.text(prompt)]);
      return response.text ?? 'لا يوجد شذوذ ملحوظ.';
    } catch (e) {
      return 'تعذر إجراء التحليل التنبؤي.';
    }
  }

  Future<String> generateHealthReport(List<VehicleData> history, Map<String, PartLifespan> parts) async {
    if (!_available || _model == null) return 'تقرير الصحة غير متاح بدون مفتاح API.';
    final prompt = '''
تقرير صحي للمركبة:
- عدد القراءات: ${history.length}
- عمر القطع: ${parts.values.map((p) => "${p.partName}: ${p.remainingPercent.toStringAsFixed(0)}%").join(', ')}
قدم ملخصاً للحالة وأولويات الصيانة.
''';
    try {
      final response = await _model!.generateContent([Content.text(prompt)]);
      return response.text ?? 'تقرير مؤقت: يبدو أن المركبة في حالة مقبولة.';
    } catch (e) {
      return 'تعذر إنشاء التقرير الصحي.';
    }
  }
}

// ============================================================
// 5. التطبيق الرئيسي مع Provider
// ============================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => OBDService()),
        Provider(create: (_) => GeminiService()),
        Provider(create: (_) => DatabaseService.instance),
      ],
      child: const CarDiagnosticApp(),
    ),
  );
}

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
  State<<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<<MainScreen> {
  int _selectedIndex = 0;

  static const List<<Widget> _screens = [
    DashboardScreen(),
    DiagnosticsScreen(),
    PartsLifespanScreen(),
    HealthReportScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final obd = context.watch<OBDService>();
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
                if (!obd.isConnected) {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectionScreen()));
                } else {
                  await obd.disconnect();
                }
              },
              backgroundColor: obd.isConnected ? Colors.red : Colors.cyan,
              child: Icon(obd.isConnected ? Icons.bluetooth_disabled : Icons.bluetooth),
            )
          : null,
    );
  }
}

// ------------------- شاشة الاتصال -------------------
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<<ConnectionScreen> {
  List<<ScanResult> _devices = [];
  bool _scanning = false;
  StreamSubscription? _scanSubscription;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    final obd = context.read<OBDService>();
    bool btReady = await obd.ensureBluetoothEnabled();
    if (!btReady) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى تفعيل البلوتوث')));
      return;
    }

    setState(() { _scanning = true; _devices.clear(); });
    
    var status = await Permission.bluetoothScan.request();
    if (status.isDenied) {
      setState(() => _scanning = false);
      return;
    }

    _scanSubscription = obd.scanDevices().listen((results) {
      if (mounted) setState(() => _devices = results);
    }, onDone: () {
      if (mounted) setState(() => _scanning = false);
    });

    await Future.delayed(const Duration(seconds: 5));
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connect(BluetoothDevice device) async {
    final obd = context.read<OBDService>();
    try {
      await obd.connectToDevice(device);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم الاتصال بـ ${device.advName.isNotEmpty ? device.advName : "OBD Device"}')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل: $e')));
    }
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
              onPressed: _scanning ? null : _startScan,
              icon: Icon(_scanning ? Icons.stop : Icons.refresh),
              label: Text(_scanning ? 'جاري البحث...' : 'بحث عن أجهزة'),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _devices.length,
              itemBuilder: (_, i) => ListTile(
                leading: const Icon(Icons.bluetooth, color: Colors.blue),
                title: Text(_devices[i].device.advName.isNotEmpty ? _devices[i].device.advName : 'جهاز OBD'),
                subtitle: Text(_devices[i].device.remoteId.str),
                onTap: () => _connect(_devices[i].device),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------- شاشة القيادة الحية -------------------
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final DatabaseService _db = DatabaseService.instance;
  VehicleData? _current;
  List<VehicleData> _history = [];
  Timer? _timer;
  String _anomalyAlert = '';

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _startLiveUpdates();
  }

  Future<void> _loadHistory() async {
    final data = await _db.getHistoricalData(limit: 100);
    if (mounted) setState(() => _history = data);
  }

  void _startLiveUpdates() {
    _timer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final obd = context.read<OBDService>();
      if (obd.isConnected) {
        VehicleData? data = await obd.readCurrentData();
        if (data != null && mounted) {
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

  Future<void> _updatePartsLifespan(double currentOdometer) async {
    final parts = await _db.loadPartsLifespan();
    bool changed = false;
    for (var part in parts.values) {
      double newUsage = currentOdometer;
      if (newUsage > part.currentUsageKm) {
        part.currentUsageKm = newUsage;
        part.remainingPercent = ((part.initialLifespanKm - part.currentUsageKm) / part.initialLifespanKm * 100).clamp(0, 100);
        changed = true;
      }
    }
    if (changed) await _db.savePartsLifespan(parts);
  }

  Future<void> _checkAnomalies(VehicleData newData) async {
    if (!mounted) return;
    String alert = '';
    if (newData.coolantTemp > 105) alert = '⚠️ تحذير: حرارة المحرك مرتفعة جداً! أوقف السيارة.';
    else if (newData.coolantTemp > 95) alert = '⚠️ ارتفاع حرارة المحرك، راقب المؤشر.';
    else if (newData.rpm > 5500) alert = '⚠️ سرعة المحرك عالية جداً (RPM).';
    else if (newData.engineLoad > 85 && newData.speed < 40) alert = '⚠️ حمل المحرك مرتفع بدون سرعة - قد يكون عطل في ناقل الحركة.';

    if (alert.isNotEmpty && alert != _anomalyAlert) {
      setState(() => _anomalyAlert = alert);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(alert), backgroundColor: Colors.red));
      await _db.insertDTCCode('PRED-001', alert, 'مرتفع');
      final ai = context.read<GeminiService>();
      String aiAlert = await ai.predictAnomalies(_history);
      if (aiAlert.isNotEmpty && !aiAlert.contains('لا يوجد') && mounted) {
        setState(() => _anomalyAlert += '\n${aiAlert.substring(0, min(100, aiAlert.length))}');
      }
    } else if (alert.isEmpty && _anomalyAlert.isNotEmpty) {
      setState(() => _anomalyAlert = '');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final obd = context.watch<OBDService>();
    if (!obd.isConnected) {
      return const Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bluetooth_disabled, size: 80, color: Colors.grey),
          SizedBox(height: 20),
          Text('غير متصل بالسيارة', style: TextStyle(fontSize: 18)),
          SizedBox(height: 10),
          Text('اضغط زر البلوتوث للاتصال', style: TextStyle(fontSize: 14, color: Colors.grey)),
        ],
      ));
    }
    if (_current == null) return const Center(child: CircularProgressIndicator());

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (_anomalyAlert.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: Colors.red[900], borderRadius: BorderRadius.circular(12)),
              child: Text(_anomalyAlert, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.cyan[900]!, Colors.cyan[800]!]), borderRadius: BorderRadius.circular(20)),
            child: Column(
              children: [
                const Text('صحة المحرك', style: TextStyle(fontSize: 18)),
                Text('${_current!.healthScore.toInt()}%', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
                LinearProgressIndicator(value: _current!.healthScore / 100, backgroundColor: Colors.white24, valueColor: const AlwaysStoppedAnimation(Colors.white)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(children: [
            _gaugeCard('RPM', _current!.rpm, 0, 8000, ''),
            _gaugeCard('السرعة', _current!.speed, 0, 200, 'كم/س'),
          ]),
          const SizedBox(height: 20),
          Row(children: [
            _gaugeCard('حرارة', _current!.coolantTemp, 0, 130, '°C', warning: 100),
            _gaugeCard('حمل المحرك', _current!.engineLoad, 0, 100, '%'),
          ]),
          const SizedBox(height: 20),
          Text('المسافة المقطوعة: ${_current!.odometer.toStringAsFixed(1)} كم', style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 10),
          Container(
            height: 150,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(16)),
            child: _history.length > 1
                ? LineChart(
                    LineChartData(
                      gridData: const FlGridData(show: true),
                      titlesData: const FlTitlesData(show: false),
                      borderData: FlBorderData(show: false),
                      minX: 0,
                      maxX: (_history.length - 1).toDouble(),
                      minY: 0,
                      maxY: 8000,
                      lineBarsData: [
                        LineChartBarData(
                          spots: _history.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value.rpm)).toList(),
                          isCurved: true,
                          color: Colors.cyan,
                          barWidth: 2,
                          dotData: const FlDotData(show: false),
                        ),
                      ],
                    ),
                  )
                : const Center(child: Text('جاري جمع البيانات...')),
          ),
        ],
      ),
    );
  }

  Widget _gaugeCard(String title, double value, double min, double max, String unit, {double? warning}) {
    double percent = max > min ? ((value - min) / (max - min)).clamp(0.0, 1.0) : 0;
    Color color = Colors.green;
    if (warning != null && value > warning) color = Colors.red;
    else if (percent > 0.8) color = Colors.orange;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(16)),
        child: Column(
          children: [
            Text(title, style: const TextStyle(fontSize: 14, color: Colors.white70)),
            const SizedBox(height: 8),
            Stack(alignment: Alignment.center, children: [
              SizedBox(
                height: 70, width: 70,
                child: CircularProgressIndicator(value: percent, strokeWidth: 6, backgroundColor: Colors.grey[700], valueColor: AlwaysStoppedAnimation(color)),
              ),
              Column(children: [
                Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text(unit, style: const TextStyle(fontSize: 10)),
              ]),
            ]),
          ],
        ),
      ),
    );
  }
}

// ------------------- شاشة التشخيص -------------------
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<<DiagnosticsScreen> {
  final DatabaseService _db = DatabaseService.instance;
  List<String> _dtcCodes = [];
  bool _scanning = false;
  Map<String, String> _analysis = {};

  Future<void> _scanDTC() async {
    final obd = context.read<OBDService>();
    if (!obd.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى الاتصال بالسيارة أولاً')));
      return;
    }
    setState(() { _scanning = true; _dtcCodes.clear(); _analysis.clear(); });
    try {
      String response = await obd.sendCommand('03\r');
      List<String> codes = _parseDTCCodes(response);
      setState(() => _dtcCodes = codes.isEmpty ? ['لا توجد رموز أعطال'] : codes);
      final ai = context.read<GeminiService>();
      for (var code in codes) {
        final analysis = await ai.analyzeDTC(code, null);
        if (mounted) setState(() => _analysis[code] = analysis);
        await _db.insertDTCCode(code, analysis.length > 200 ? analysis.substring(0, 200) : analysis, 'متوسط');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  List<String> _parseDTCCodes(String resp) {
    List<String> list = [];
    if (resp.isEmpty) return list;
    resp = resp.replaceAll(' ', '').replaceAll('\r', '').replaceAll('\n', '').replaceAll('>', '');
    if (resp.contains('43') && resp.length > 10) {
      String hex = resp.substring(4);
      for (int i = 0; i < hex.length; i += 4) {
        if (i + 4 <= hex.length) {
          String codeHex = hex.substring(i, i + 4);
          if (codeHex != '0000') list.add(_hexToDTC(codeHex));
        }
      }
    }
    return list;
  }

  String _hexToDTC(String hex) {
    const map = {'0':'P0','1':'P1','2':'P2','3':'P3','4':'C0','5':'C1','6':'C2','7':'C3','8':'B0','9':'B1','A':'B2','B':'B3','C':'U0','D':'U1','E':'U2','F':'U3'};
    return '${map[hex[0].toUpperCase()] ?? 'P'}${hex.substring(1)}';
  }

  Future<void> _clearDTC() async {
    final obd = context.read<OBDService>();
    if (!obd.isConnected) return;
    try {
      await obd.sendCommand('04\r');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم مسح الرموز')));
        setState(() => _dtcCodes.clear());
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تشخيص الأعطال'), backgroundColor: Colors.cyan[900], actions: [
        IconButton(onPressed: _scanning ? null : _scanDTC, icon: Icon(_scanning ? Icons.hourglass_empty : Icons.search)),
        IconButton(onPressed: _clearDTC, icon: const Icon(Icons.cleaning_services)),
      ]),
      body: _scanning
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircularProgressIndicator(), SizedBox(height: 16), Text('جاري فحص الأعطال...')]))
          : ListView.builder(
              itemCount: _dtcCodes.length,
              itemBuilder: (_, i) => Card(
                margin: const EdgeInsets.all(8),
                child: ExpansionTile(
                  leading: const Icon(Icons.error, color: Colors.red),
                  title: Text(_dtcCodes[i], style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: _analysis[_dtcCodes[i]] != null
                      ? Text(_analysis[_dtcCodes[i]]!.length > 80 ? '${_analysis[_dtcCodes[i]]!.substring(0, 80)}...' : _analysis[_dtcCodes[i]]!)
                      : const Text('اضغط للتحليل'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_analysis[_dtcCodes[i]] ?? 'جاري التحليل...', style: const TextStyle(height: 1.4)),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

// ------------------- شاشة عمر القطع -------------------
class PartsLifespanScreen extends StatefulWidget {
  const PartsLifespanScreen({super.key});

  @override
  State<<PartsLifespanScreen> createState() => _PartsLifespanScreenState();
}

class _PartsLifespanScreenState extends State<<PartsLifespanScreen> {
  final DatabaseService _db = DatabaseService.instance;
  Map<String, PartLifespan> _parts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadParts();
  }

  Future<void> _loadParts() async {
    final parts = await _db.loadPartsLifespan();
    if (mounted) setState(() { _parts = parts; _loading = false; });
  }

  Future<void> _resetPart(PartLifespan part) async {
    final newDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (newDate != null && mounted) {
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_parts.isEmpty) return const Center(child: Text('لا توجد بيانات'));
    return Scaffold(
      appBar: AppBar(title: const Text('عمر القطع'), backgroundColor: Colors.cyan[900]),
      body: ListView.builder(
        itemCount: _parts.length,
        itemBuilder: (_, i) {
          final part = _parts.values.elementAt(i);
          return Card(
            margin: const EdgeInsets.all(10),
            child: ListTile(
              leading: const Icon(Icons.build, color: Colors.orange),
              title: Text(part.partName, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('المتبقي: ${part.remainingPercent.toStringAsFixed(0)}% (${part.remainingKm.toStringAsFixed(0)} كم)'),
                  LinearProgressIndicator(value: part.remainingPercent / 100, backgroundColor: Colors.grey[700], valueColor: const AlwaysStoppedAnimation(Colors.green)),
                ],
              ),
              trailing: part.remainingPercent < 20 ? const Icon(Icons.warning, color: Colors.red) : null,
              onTap: () => _resetPart(part),
            ),
          );
        },
      ),
    );
  }
}

// ------------------- شاشة التقرير الصحي و SOS -------------------
class HealthReportScreen extends StatefulWidget {
  const HealthReportScreen({super.key});

  @override
  State<<HealthReportScreen> createState() => _HealthReportScreenState();
}

class _HealthReportScreenState extends State<<HealthReportScreen> {
  final DatabaseService _db = DatabaseService.instance;
  String _report = '';
  bool _loading = false;
  Position? _position;
  String _address = 'جاري تحديد الموقع...';

  @override
  void initState() {
    super.initState();
    _getLocation();
  }

  Future<void> _getLocation() async {
    try {
      var status = await Permission.location.request();
      if (status.isGranted) {
        Position pos = await Geolocator.getCurrentPosition();
        if (mounted) setState(() => _position = pos);
        List<<Placemark> placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (placemarks.isNotEmpty && mounted) {
          setState(() => _address = '${placemarks.first.street ?? ''}, ${placemarks.first.locality ?? ''}');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _address = 'تعذر تحديد الموقع');
    }
  }

  Future<void> _generateReport() async {
    setState(() { _loading = true; _report = ''; });
    try {
      final history = await _db.getHistoricalData(limit: 100);
      final parts = await _db.loadPartsLifespan();
      final ai = context.read<GeminiService>();
      final report = await ai.generateHealthReport(history, parts);
      if (mounted) setState(() { _report = report; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _report = 'خطأ: $e'; _loading = false; });
    }
  }

  Future<void> _sendSOS() async {
    if (_position == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الموقع غير متاح')));
      return;
    }
    final obd = context.read<OBDService>();
    String message = '🚨 SOS من CarDiagnosticAI Pro\nالموقع: $_address\nالإحداثيات: ${_position!.latitude},${_position!.longitude}\nالوقت: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now())}\nحالة السيارة: ${obd.isConnected ? "متصل" : "غير متصل"}';
    Uri smsUri = Uri(scheme: 'sms', path: '', queryParameters: {'body': message});
    try {
      if (await canLaunchUrl(smsUri)) {
        await launchUrl(smsUri);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح تطبيق الرسائل')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('التقرير الصحي والطوارئ'), backgroundColor: Colors.cyan[900]),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: _loading ? null : _generateReport,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('توليد تقرير صحي بالذكاء الاصطناعي'),
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
            ),
            const SizedBox(height: 20),
            if (_loading) const CircularProgressIndicator(),
            if (_report.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(16)),
                child: Text(_report, style: const TextStyle(height: 1.5)),
              ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.red[900], borderRadius: BorderRadius.circular(16)),
              child: Column(
                children: [
                  const Text('حالة الطوارئ', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(_address),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _sendSOS,
                          icon: const Icon(Icons.sos),
                          label: const Text('إرسال SOS'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            if (_position != null) {
                              String url = 'https://www.google.com/maps/search/?api=1&query=${_position!.latitude},${_position!.longitude}';
                              Uri uri = Uri.parse(url);
                              if (await canLaunchUrl(uri)) await launchUrl(uri);
                            }
                          },
                          icon: const Icon(Icons.map),
                          label: const Text('فتح الخريطة'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
