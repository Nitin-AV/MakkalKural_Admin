import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import '../bloc/login/login_cubit.dart';
import '../bloc/login/login_state.dart';
import 'home_screen.dart';

// ─── light theme (matches home screen) ───────────────────────────────────────
const _kBg        = Color(0xfff0f4f8);
const _kBlue      = Color(0xff1565c0);
const _kBlueLight = Color(0xff42a5f5);
const _kTextDark  = Color(0xff1a2340);
const _kTextMid   = Color(0xff5a6a85);
const _kDivider   = Color(0xffe8edf3);

class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen>
    with SingleTickerProviderStateMixin {
  final _mobileCtrl    = TextEditingController();
  final _otpCtrl       = TextEditingController();
  final _passcodeCtrl  = TextEditingController();
  final _confirmCtrl   = TextEditingController();

  bool _loading = false;

  late final AnimationController _animCtrl;
  late final Animation<double>    _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350));
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeIn);
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _mobileCtrl.dispose();
    _otpCtrl.dispose();
    _passcodeCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  int _stepOf(AuthState s) {
    if (s is OtpRequired) return 1;
    if (s is CreatePasscode || s is PasscodeRequired) return 2;
    return 0;
  }

  void _animIn() { _animCtrl.reset(); _animCtrl.forward(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: BlocConsumer<AuthCubit, AuthState>(
        listener: (context, state) {
          setState(() => _loading = state is AuthLoading);

          if (state is Authenticated) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const AdminHomeScreen()),
            );
          }

          if (state is AuthError) {
            _snackError(state.message);
            final cubit = context.read<AuthCubit>();
            if (state.message.contains('Passcode')) cubit.resetToPasscode();
            else if (state.message.contains('OTP')) cubit.resetToOtp();
            else cubit.resetToInitial();
            _animIn();
          }

          if (state is OtpRequired ||
              state is CreatePasscode ||
              state is PasscodeRequired) {
            _animIn();
          }
        },
        builder: (context, state) {
          return Stack(children: [
            // ── background ────────────────────────────────────────────
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xffe8f0fe), _kBg, Color(0xffdce8ff)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),

            // ── decorative blobs ──────────────────────────────────────
            Positioned(
              top: -80,
              right: -60,
              child: _blob(220, _kBlueLight.withOpacity(0.18)),
            ),
            Positioned(
              bottom: -100,
              left: -80,
              child: _blob(260, _kBlue.withOpacity(0.08)),
            ),

            // ── centered card ─────────────────────────────────────────
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 40),
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: Container(
                    width: 440,
                    padding: const EdgeInsets.fromLTRB(36, 40, 36, 36),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: _kDivider),
                      boxShadow: [
                        BoxShadow(
                          blurRadius: 40,
                          spreadRadius: 0,
                          color: _kBlue.withOpacity(0.1),
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // logo
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _kBlue.withOpacity(0.08),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: _kBlue.withOpacity(0.2)),
                          ),
                          child: Image.asset('images/icon.png', height: 52),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Smart Civic Admin',
                          style: GoogleFonts.poppins(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: _kTextDark,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Civic Issue Management Portal',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: _kTextMid,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // step indicator
                        _StepIndicator(currentStep: _stepOf(state)),
                        const SizedBox(height: 28),

                        // ── fields ──
                        if (state is AuthInitial)
                          _field(
                            ctrl: _mobileCtrl,
                            hint: 'Mobile Number',
                            icon: Icons.phone_android_rounded,
                            keyType: TextInputType.phone,
                          ),

                        if (state is OtpRequired)
                          _field(
                            ctrl: _otpCtrl,
                            hint: 'Enter 6-digit OTP',
                            icon: Icons.verified_rounded,
                            keyType: TextInputType.number,
                            maxLen: 6,
                          ),

                        if (state is CreatePasscode) ...[
                          _field(
                            ctrl: _passcodeCtrl,
                            hint: 'Create 4-digit Passcode',
                            icon: Icons.lock_outline_rounded,
                            keyType: TextInputType.number,
                            obscure: true,
                            maxLen: 4,
                          ),
                          const SizedBox(height: 12),
                          _field(
                            ctrl: _confirmCtrl,
                            hint: 'Confirm Passcode',
                            icon: Icons.lock_reset_rounded,
                            keyType: TextInputType.number,
                            obscure: true,
                            maxLen: 4,
                          ),
                        ],

                        if (state is PasscodeRequired)
                          _field(
                            ctrl: _passcodeCtrl,
                            hint: 'Enter Passcode',
                            icon: Icons.lock_rounded,
                            keyType: TextInputType.number,
                            obscure: true,
                            maxLen: 4,
                          ),

                        const SizedBox(height: 24),

                        // ── action button ──
                        if (state is AuthInitial)
                          _actionBtn(
                            label: 'Continue',
                            icon: Icons.arrow_forward_rounded,
                            onTap: () {
                              if (_mobileCtrl.text.trim().isEmpty) {
                                _snackError('Enter mobile number');
                                return;
                              }
                              context
                                  .read<AuthCubit>()
                                  .checkAdmin(_mobileCtrl.text.trim());
                            },
                          ),

                        if (state is OtpRequired)
                          _actionBtn(
                            label: 'Verify OTP',
                            icon: Icons.verified_rounded,
                            onTap: () {
                              if (_otpCtrl.text.trim().isEmpty) {
                                _snackError('Enter OTP');
                                return;
                              }
                              context
                                  .read<AuthCubit>()
                                  .verifyOtp(_otpCtrl.text.trim());
                            },
                          ),

                        if (state is CreatePasscode)
                          _actionBtn(
                            label: 'Create Passcode',
                            icon: Icons.lock_open_rounded,
                            onTap: () {
                              if (_passcodeCtrl.text != _confirmCtrl.text) {
                                _snackError('Passcodes do not match');
                                return;
                              }
                              context
                                  .read<AuthCubit>()
                                  .createPasscode(_passcodeCtrl.text.trim());
                            },
                          ),

                        if (state is PasscodeRequired)
                          _actionBtn(
                            label: 'Login',
                            icon: Icons.login_rounded,
                            onTap: () {
                              if (_passcodeCtrl.text.trim().isEmpty) {
                                _snackError('Enter passcode');
                                return;
                              }
                              context
                                  .read<AuthCubit>()
                                  .loginWithPasscode(
                                      _passcodeCtrl.text.trim());
                            },
                          ),

                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.location_on_rounded,
                                size: 12,
                                color: _kBlue.withOpacity(0.5)),
                            const SizedBox(width: 5),
                            Text(
                              'Ward access verified via GPS',
                              style: GoogleFonts.poppins(
                                  fontSize: 11, color: _kTextMid),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ── loading overlay ───────────────────────────────────────
            if (_loading)
              Positioned.fill(
                child: Container(
                  color: Colors.black26,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 20,
                            color: Colors.black.withOpacity(0.12),
                          )
                        ],
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const CircularProgressIndicator(color: _kBlue),
                        const SizedBox(height: 16),
                        Text('Please wait…',
                            style: GoogleFonts.poppins(
                                color: _kTextMid, fontSize: 13)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]);
        },
      ),
    );
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  Widget _blob(double size, Color color) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      );

  Widget _field({
    required TextEditingController ctrl,
    required String hint,
    required IconData icon,
    TextInputType keyType = TextInputType.text,
    bool obscure = false,
    int? maxLen,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: keyType,
      obscureText: obscure,
      maxLength: maxLen,
      style: GoogleFonts.poppins(color: _kTextDark, fontSize: 14),
      cursorColor: _kBlue,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.poppins(color: _kTextMid, fontSize: 14),
        prefixIcon: Icon(icon, color: _kBlue.withOpacity(0.6), size: 20),
        counterStyle: GoogleFonts.poppins(color: _kTextMid, fontSize: 10),
        filled: true,
        fillColor: _kBg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: _kDivider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: _kDivider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _kBlue, width: 1.5),
        ),
      ),
    );
  }

  Widget _actionBtn({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [_kBlueLight, _kBlue],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: _kBlue.withOpacity(0.35),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label,
              style: GoogleFonts.poppins(
                  fontSize: 15, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
  }

  void _snackError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: const Color(0xffb71c1c),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      content: Row(children: [
        const Icon(Icons.error_outline, color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(
            child: Text(msg,
                style: GoogleFonts.poppins(
                    color: Colors.white, fontSize: 13))),
      ]),
    ));
  }
}

// ─── step indicator ───────────────────────────────────────────────────────────

class _StepIndicator extends StatelessWidget {
  final int currentStep;
  const _StepIndicator({required this.currentStep});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (i) {
        final done   = i < currentStep;
        final active = i == currentStep;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            width:  active ? 28 : 10,
            height: 10,
            decoration: BoxDecoration(
              color: done || active
                  ? _kBlue
                  : _kDivider,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          if (i < 2)
            Container(
              width: 24,
              height: 2,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: done ? _kBlue : _kDivider,
            ),
        ]);
      }),
    );
  }
}
