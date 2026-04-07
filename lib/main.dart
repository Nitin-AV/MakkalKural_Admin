import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_civic_admin/bloc/login/login_cubit.dart';
import 'package:smart_civic_admin/firebase_options.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  await Supabase.initialize(
    url: 'https://wriwcwwnywfqyqvjdvod.supabase.co',
    anonKey: 'xxxPASTE_YOUR_SUPABASE_ANON_KEY_HERExxx',
  );

  // Check if admin is already logged in
  final prefs = await SharedPreferences.getInstance();
  final adminId = prefs.getString('admin_id');

  runApp(SmartCivicAdmin(isLoggedIn: adminId != null));
}

class SmartCivicAdmin extends StatelessWidget {
  final bool isLoggedIn;
  const SmartCivicAdmin({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Civic Admin',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: isLoggedIn
          ? const AdminHomeScreen()
          : BlocProvider(
              create: (_) => AuthCubit(),
              child: const AdminLoginScreen(),
            ),
    );
  }
}