import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mrz_parser/mrz_parser.dart';
import 'package:dmrtd/dmrtd.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: IdScannerPage(),
  ));
}

class IdScannerPage extends StatefulWidget {
  const IdScannerPage({super.key});
  @override
  State<IdScannerPage> createState() => _IdScannerPageState();
}

class _IdScannerPageState extends State<IdScannerPage> {
  CameraController? _cameraController;
  final TextRecognizer _textRecognizer = TextRecognizer();
  bool _isProcessing = false;
  String _status = "وجه الكاميرا إلى أسطر MRZ في ظهر البطاقة";
  Map<String, String>? _cardData;
  Uint8List? _facePhoto;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    await [Permission.camera].request();
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    _cameraController = CameraController(cameras.first, ResolutionPreset.high, enableAudio: false);
    await _cameraController!.initialize();
    if (!mounted) return;
    setState(() {});
    _startMrzScan();
  }

  void _startMrzScan() {
    Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted || _cardData != null || _isProcessing || _cameraController == null || !_cameraController!.value.isInitialized) {
        if (_cardData != null) timer.cancel();
        return;
      }
      _isProcessing = true;
      try {
        final file = await _cameraController!.takePicture();
        final inputImage = InputImage.fromFilePath(file.path);
        final recognized = await _textRecognizer.processImage(inputImage);
        final lines = recognized.text
            .split('\n')
            .map((e) => e.replaceAll(' ', '').toUpperCase())
            .where((e) => e.length >= 28)
            .toList();
        if (lines.length >= 3) {
          final mrz = MRZParser.tryParse(lines.sublist(lines.length - 3));
          if (mrz != null) {
            timer.cancel();
            await _readNfcChip(mrz);
          }
        }
      } catch (_) {}
      _isProcessing = false;
    });
  }

  Future<void> _readNfcChip(MRZResult mrz) async {
    setState(() => _status = "تم التقاط MRZ! ألصق البطاقة بظهر الهاتف (NFC)...");
    final provider = NfcProvider();
    try {
      await provider.connect();
      final mrtd = MrtdApi(provider);
      final bacKey = DBAKey(mrz.documentNumber, mrz.birthDate, mrz.expiryDate);
      await mrtd.initSessionViaBAC(bacKey);

      final dg1Raw = await mrtd.readDG1();
      final dg1 = DG1(dg1Raw);

      Uint8List? photoBytes;
      try {
        final dg2Raw = await mrtd.readDG2();
        final dg2 = DG2(dg2Raw);
        if (dg2.imageData != null) photoBytes = Uint8List.fromList(dg2.imageData!);
      } catch (_) {}

      await provider.disconnect();
      setState(() {
        _facePhoto = photoBytes;
        _cardData = {
          "اللقب": dg1.mrz.surnames,
          "الاسم": dg1.mrz.givenNames,
          "رقم الوثيقة": dg1.mrz.documentNumber,
          "تاريخ الميلاد": dg1.mrz.birthDate.toString().split(' ')[0],
          "تاريخ الانتهاء": dg1.mrz.expiryDate.toString().split(' ')[0],
          "الجنس": dg1.mrz.sex.name,
          "الجنسية": dg1.mrz.nationality,
        };
        _status = "تمت قراءة الشريحة بنجاح";
      });
    } catch (e) {
      setState(() => _status = "خطأ NFC: تأكد من تفعيل NFC وثبات البطاقة.\n($e)");
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("قارئ البطاقة البيومترية"), backgroundColor: Colors.teal),
      body: _cardData != null
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_facePhoto != null) Center(child: Image.memory(_facePhoto!, height: 160)),
                const SizedBox(height: 16),
                ..._cardData!.entries.map((e) => Card(
                      child: ListTile(
                        title: Text(e.key),
                        subtitle: Text(e.value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ),
                    )),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _cardData = null;
                      _facePhoto = null;
                      _status = "وجه الكاميرا إلى أسطر MRZ في ظهر البطاقة";
                    });
                    _startMrzScan();
                  },
                  child: const Text("مسح بطاقة جديدة"),
                )
              ],
            )
          : Column(
              children: [
                Expanded(
                  child: _cameraController != null && _cameraController!.value.isInitialized
                      ? CameraPreview(_cameraController!)
                      : const Center(child: CircularProgressIndicator()),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  color: Colors.black87,
                  child: Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
                )
              ],
            ),
    );
  }
}
