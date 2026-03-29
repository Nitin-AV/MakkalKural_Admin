abstract class AuthState {}

class AuthInitial extends AuthState {}

class AuthLoading extends AuthState {}

class OtpRequired extends AuthState {}

class CreatePasscode extends AuthState {}

class PasscodeRequired extends AuthState {}

class Authenticated extends AuthState {}

class AuthError extends AuthState {
  final String message;
  AuthError(this.message);
}