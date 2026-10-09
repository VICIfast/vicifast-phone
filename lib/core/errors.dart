enum AppErrorCode {
  invalidCredentials,
  codeRequired,
  codeRejected,
  accountOff,
  mobileSignInOff,
  appNotSubscribed,
  companyNotFound,
  webSessionConflict,
  signedInElsewhere,
  tooManyTries,
  sessionEnded,
  phoneSystemDown,
  ipv6Only,
  noInternet,
  noCustomerOnCall,
  lineDown,
  onCallOnComputer,
  noCallRow,
  featureOff,
  updateRequired,
  unknown,
}

class AppError implements Exception {
  const AppError(this.code, {this.detail, this.status});

  final AppErrorCode code;
  final String? detail;
  final int? status;

  /// What the agent reads. Never includes server codes or exception text;
  /// [detail] goes to diagnostics only.
  String get message => switch (code) {
    AppErrorCode.invalidCredentials => "That username or password didn't match.",
    AppErrorCode.codeRequired => 'Enter the code from your authenticator app.',
    AppErrorCode.codeRejected => "That code didn't work. Wait for a new one and try again.",
    AppErrorCode.accountOff => 'Your account is turned off. Ask your supervisor.',
    AppErrorCode.mobileSignInOff => 'Mobile sign-in is turned off for your company. Ask your supervisor.',
    AppErrorCode.appNotSubscribed => "Your company hasn't turned on the mobile app. Ask your supervisor.",
    AppErrorCode.companyNotFound => "We couldn't find that company code.",
    AppErrorCode.webSessionConflict =>
      "You're signed in on a computer. Sign out there, or continue here to move your session.",
    AppErrorCode.signedInElsewhere => 'You signed in on another phone, so this one was signed out.',
    AppErrorCode.tooManyTries => 'Too many tries. Wait a few minutes and try again.',
    AppErrorCode.sessionEnded => 'Your session ended. Sign in again.',
    AppErrorCode.phoneSystemDown => "Your company's phone system isn't answering. Try again in a minute.",
    AppErrorCode.ipv6Only => 'Your network has no IPv4 address. Switch to another Wi-Fi or to mobile data.',
    AppErrorCode.noInternet => "Can't connect. Check your internet connection.",
    AppErrorCode.noCustomerOnCall => "There's no customer on this call anymore.",
    AppErrorCode.lineDown => "Your phone line isn't connected yet. Wait a moment and try again.",
    AppErrorCode.onCallOnComputer => "You're on a call on your computer. Finish it there, then go ready here.",
    AppErrorCode.noCallRow => "This call was already closed on the server, so there's nothing to save.",
    AppErrorCode.featureOff => 'Your company has turned this off.',
    AppErrorCode.updateRequired => 'Update the app to keep working.',
    AppErrorCode.unknown => 'Something went wrong. Try again.',
  };

  /// Errors after which the app must return to the sign-in screen.
  bool get endsSession =>
      code == AppErrorCode.signedInElsewhere ||
      code == AppErrorCode.appNotSubscribed ||
      code == AppErrorCode.sessionEnded ||
      code == AppErrorCode.accountOff ||
      code == AppErrorCode.updateRequired;

  static AppErrorCode parseReason(String? reason) {
    switch ((reason ?? '').trim().toUpperCase()) {
      case 'INVALID_CREDS':
        return AppErrorCode.invalidCredentials;
      case 'MFA_REQUIRED':
        return AppErrorCode.codeRequired;
      case 'MFA_FAILED':
        return AppErrorCode.codeRejected;
      case 'AGENT_DISABLED':
      case 'ACCOUNT_NOT_AVAILABLE':
        return AppErrorCode.accountOff;
      case 'SELF_SERVICE_DISABLED':
        return AppErrorCode.mobileSignInOff;
      case 'APP_NOT_SUBSCRIBED':
        return AppErrorCode.appNotSubscribed;
      case 'SLUG_NOT_FOUND':
        return AppErrorCode.companyNotFound;
      case 'WEB_SESSION_CONFLICT':
        return AppErrorCode.webSessionConflict;
      case 'DEVICE_REVOKED':
        return AppErrorCode.signedInElsewhere;
      case 'RATE_LIMITED':
      case 'CAPTCHA_REQUIRED':
        return AppErrorCode.tooManyTries;
      case 'NO_ACTIVE_SESSION':
        return AppErrorCode.sessionEnded;
      case 'BOX_UNREACHABLE':
      case 'BOX_NOT_PROVISIONED':
      case 'BAD_SHIM_RESPONSE':
      case 'SERVER_NOT_FOUND':
      case 'SHIM_EXCEPTION':
        return AppErrorCode.phoneSystemDown;
      case 'NO_IPV4':
        return AppErrorCode.ipv6Only;
      case 'PLATFORM_UNREACHABLE':
        return AppErrorCode.noInternet;
      case 'NO_CUSTOMER_IN_BRIDGE':
        return AppErrorCode.noCustomerOnCall;
      case 'DISPOSITION_NO_ROW':
        return AppErrorCode.noCallRow;
      case 'STATS_DISABLED':
      case 'TAB_DISABLED':
      case 'REPORTS_DISABLED':
        return AppErrorCode.featureOff;
      case 'UPGRADE_REQUIRED':
        return AppErrorCode.updateRequired;
      default:
        return AppErrorCode.unknown;
    }
  }

  @override
  String toString() => 'AppError($code${detail == null ? '' : ': $detail'})';
}
