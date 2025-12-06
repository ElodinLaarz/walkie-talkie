import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'bloc/bluetooth_bloc.dart';
import 'services/audio_service.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive for local storage
  await Hive.initFlutter();

  // Request permissions
  await _requestPermissions();

  runApp(const WalkieTalkieApp());
}

Future<void> _requestPermissions() async {
  // Request all required permissions
  await [
    Permission.bluetoothConnect,
    Permission.bluetoothScan,
    Permission.bluetoothAdvertise,
    Permission.microphone,
    Permission.notification,
  ].request();
}

class WalkieTalkieApp extends StatelessWidget {
  const WalkieTalkieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => BluetoothBloc(audioService: AudioService()),
      child: MaterialApp(
        title: 'Walkie Talkie',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: Brightness.dark,
          ),
          textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
