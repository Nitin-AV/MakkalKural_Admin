import 'dart:convert';
import 'package:bloc/bloc.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    hide AuthState;

import 'login_state.dart';

class AuthCubit extends Cubit<AuthState> {
  AuthCubit() : super(AuthInitial());

  final supabase = Supabase.instance.client;
  final firebaseAuth = FirebaseAuth.instance;

  Map<String, dynamic>? adminData;
  String? verificationId;
  int? wardId;

  // ===============================
  // 1️⃣ CHECK ADMIN
  // ===============================

  Future<void> checkAdmin(String mobile) async {
    emit(AuthLoading());

    try {

      final admin = await supabase
          .from('admin')
          .select()
          .eq('mobile_number', mobile)
          .maybeSingle();

      if (admin == null) {
        emit(AuthError("Admin not registered"));
        return;
      }

      adminData = admin;

      wardId = admin['ward_id'];

      // detect location AFTER admin check
      await detectLocation();

      // check OTP rule
      DateTime? otpVerifiedAt =
          admin['otp_verified_at'] != null
              ? DateTime.parse(admin['otp_verified_at'])
              : null;

      if (otpVerifiedAt == null ||
          DateTime.now().difference(otpVerifiedAt).inDays >= 10) {

        await sendOtp(mobile);

      } else {

        if (admin['passcode_hash'] == null) {
          emit(CreatePasscode());
        } else {
          emit(PasscodeRequired());
        }

      }

    } catch (e) {
      emit(AuthError("Login failed"));
    }
  }

  // ===============================
  // 2️⃣ LOCATION CHECK
  // ===============================

  Future<void> detectLocation() async {

    Position position = await Geolocator.getCurrentPosition();

    print("LAT: ${position.latitude}");
    print("LNG: ${position.longitude}");

    final ward = await supabase
        .from('wards')
        .select()
        .lte('min_lat', position.latitude)
        .gte('max_lat', position.latitude)
        .lte('min_lng', position.longitude)
        .gte('max_lng', position.longitude)
        .maybeSingle();

    if (ward == null) {
      throw Exception("Not inside ward area");
    }

    if (ward['id'] != wardId) {
      throw Exception("Wrong ward login attempt");
    }

    print("Ward verified");
  }

  // ===============================
  // 3️⃣ SEND OTP
  // ===============================

  Future<void> sendOtp(String mobile) async {

    try {

      String phone = "+91$mobile";

      await firebaseAuth.verifyPhoneNumber(

        phoneNumber: phone,

        verificationCompleted: (_) {},

        verificationFailed: (e) {
          emit(AuthError(e.message ?? "OTP Failed"));
        },

        codeSent: (verId, _) {
          verificationId = verId;
          emit(OtpRequired());
        },

        codeAutoRetrievalTimeout: (verId) {
          verificationId = verId;
        },
      );

    } catch (e) {
      emit(AuthError("OTP sending failed"));
    }
  }

  // ===============================
  // 4️⃣ VERIFY OTP
  // ===============================

  Future<void> verifyOtp(String otp) async {

    emit(AuthLoading());

    try {

      PhoneAuthCredential credential =
          PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: otp,
      );

      await firebaseAuth.signInWithCredential(credential);

      await supabase.from('admin').update({
        'otp_verified_at': DateTime.now().toIso8601String(),
      }).eq('id', adminData!['id']);

      if (adminData!['passcode_hash'] == null) {
        emit(CreatePasscode());
      } else {
        emit(PasscodeRequired());
      }

    } catch (e) {
      emit(AuthError("Invalid OTP"));
    }
  }

  // ===============================
  // 5️⃣ CREATE PASSCODE
  // ===============================

  Future<void> createPasscode(String passcode) async {

    emit(AuthLoading());

    try {

      String hashed =
          sha256.convert(utf8.encode(passcode)).toString();

      await supabase.from('admin').update({
        'passcode_hash': hashed
      }).eq('id', adminData!['id']);

      emit(PasscodeRequired());

    } catch (e) {
      emit(AuthError("Passcode creation failed"));
    }
  }

  // ===============================
  // 6️⃣ LOGIN
  // ===============================

  Future<void> loginWithPasscode(String passcode) async {

    emit(AuthLoading());

    try {

      String hashed =
          sha256.convert(utf8.encode(passcode)).toString();

      if (hashed != adminData!['passcode_hash']) {
        emit(AuthError("Wrong passcode"));
        return;
      }

      final prefs = await SharedPreferences.getInstance();

      await prefs.setString("admin_id", adminData!['id']);

      emit(Authenticated());

    } catch (e) {
      emit(AuthError("Login failed"));
    }
  }

  // ===============================
  // 7️⃣ LOGOUT
  // ===============================

  Future<void> logout() async {

    final prefs = await SharedPreferences.getInstance();

    await prefs.clear();

    await firebaseAuth.signOut();

    emit(AuthInitial());
  }

  // ===============================
  // 8️⃣ PUBLIC RESET HELPERS
  // ===============================

  void resetToInitial() => emit(AuthInitial());
  void resetToOtp() => emit(OtpRequired());
  void resetToPasscode() => emit(PasscodeRequired());
}