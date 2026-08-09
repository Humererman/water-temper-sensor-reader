import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 水温计',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const BluetoothPage(),
    );
  }
}

class BluetoothPage extends StatefulWidget {
  const BluetoothPage({super.key});
  @override
  State<BluetoothPage> createState() => _BluetoothPageState();
}

class _BluetoothPageState extends State<BluetoothPage> {
  BluetoothDevice? _connectedDevice;
  StreamSubscription<List<int>>? _subscription;
  String _status = "未连接";
  
  // 两块显示区的数据
  String _currentTemp = "---";
  String _finalAvgTemp = "---";
  String _measureState = "等待开始..."; // 当前状态文字
  
  final List<double> _history = [];
  bool _isMeasuring = false;
  bool _isFinished = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await [Permission.bluetooth, Permission.bluetoothConnect, Permission.location].request();
  }

  Future<void> _connectToDevice() async {
    if (_connectedDevice != null) return;
    setState(() => _status = "正在扫描蓝牙...");

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.device.platformName == "ESP32_水温计") {
          FlutterBluePlus.stopScan();
          _connect(r.device);
          return;
        }
      }
    });
  }

  void _connect(BluetoothDevice device) async {
    setState(() => _status = "正在连接...");
    try {
      await device.connect(autoConnect: true);
      _connectedDevice = device;
      setState(() => _status = "已连接");

      _subscription = device.onDataReceived().listen((data) {
        String str = String.fromCharCodes(data);
        _parseData(str);
      });
    } catch (e) {
      setState(() => _status = "连接失败: $e");
    }
  }

  void _parseData(String data) {
    data = data.trim();
    if (data == "OK") {
      setState(() {
        _isMeasuring = true;
        _isFinished = false;
        _finalAvgTemp = "---";
        _measureState = "⏳ 测量中，请保持探头静止...";
      });
      return;
    }
    if (data.startsWith("TEMP:")) {
      String tempStr = data.substring(5);
      double? temp = double.tryParse(tempStr);
      if (temp != null) {
        setState(() {
          _currentTemp = tempStr;
          if (_isMeasuring && !_isFinished) {
            _history.add(temp);
            // 只要历史记录超过5个就开始检测稳定性
            if (_history.length >= 5) {
              var last5 = _history.sublist(_history.length - 5);
              double max = last5.reduce((a, b) => a > b ? a : b);
              double min = last5.reduce((a, b) => a < b ? a : b);
              
              // 如果5个数的极差小于等于0.3，判定为稳定
              if (max - min <= 0.3) {
                _isFinished = true;
                _finalAvgTemp = (last5.reduce((a, b) => a + b) / 5).toStringAsFixed(1);
                _connectedDevice?.write("stop".codeUnits);
                _isMeasuring = false;
                _measureState = "✅ 测量已自动结束，水温稳定！";
              }
            }
          }
        });
      }
    }
  }

  void _start() async {
    if (_connectedDevice == null) return;
    _history.clear();
    _currentTemp = "---";
    _finalAvgTemp = "---";
    _isFinished = false;
    _isMeasuring = false;
    _measureState = "等待开始...";
    _connectedDevice?.write("start".codeUnits);
  }

  void _stop() async {
    if (_connectedDevice == null) return;
    _isMeasuring = false;
    _isFinished = true;
    _connectedDevice?.write("stop".codeUnits);
    _measureState = "🛑 已手动停止测量";
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _connectedDevice?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("智能水温测量仪")),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text("连接状态: $_status", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 20),

            // 蓝牙连接按钮（未连接时显示）
            if (_connectedDevice == null)
              ElevatedButton(onPressed: _connectToDevice, child: const Text("搜索并连接蓝牙设备"))
            else ...[
              
              // 状态提示信息
              Text(_measureState, style: TextStyle(fontSize: 14, color: _isFinished ? Colors.green : Colors.blue)),
              const Divider(height: 30),

              // 1️⃣ 【实时数据显示区】
              const Text("📊 实时水温 (持续跳动)", style: TextStyle(fontSize: 16, color: Colors.black87)),
              Text("$_currentTemp ℃", style: const TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: Colors.blue)),

              const SizedBox(height: 20),

              // 2️⃣ 【最终平均值显示区】
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _isFinished ? Colors.green.shade50 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _isFinished ? Colors.green : Colors.transparent, width: 2),
                ),
                child: Column(
                  children: [
                    const Text("✅ 最终稳定平均水温", style: TextStyle(fontSize: 16, color: Colors.black87)),
                    const SizedBox(height: 5),
                    Text(_finalAvgTemp == "---" ? "等待测量结束..." : "$_finalAvgTemp ℃", 
                      style: TextStyle(
                        fontSize: 32, 
                        fontWeight: FontWeight.bold, 
                        color: _isFinished ? Colors.green : Colors.grey
                      )
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 30),

              // 控制按钮组
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: _isMeasuring ? null : _start, // 正在测量时禁用开始按钮
                    child: const Text("开始测量")
                  ),
                  const SizedBox(width: 20),
                  ElevatedButton(
                    onPressed: _stop, 
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    child: const Text("停止")
                  ),
                ],
              ),
            ]
          ],
        ),
      ),
    );
  }
}