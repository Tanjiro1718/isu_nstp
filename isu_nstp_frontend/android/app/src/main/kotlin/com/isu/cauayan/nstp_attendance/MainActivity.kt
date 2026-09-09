package com.isu.cauayan.nstp_attendance

import io.flutter.embedding.android.FlutterFragmentActivity

/// Must extend FlutterFragmentActivity, not FlutterActivity.
///
/// local_auth shows Android's BiometricPrompt, which is a Fragment and can only
/// attach to a FragmentActivity. With a plain FlutterActivity every
/// authenticate() call throws PlatformException(no_fragment_activity), which
/// looks exactly like "no biometrics enrolled" from Dart.
class MainActivity : FlutterFragmentActivity()
