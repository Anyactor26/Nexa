import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'contacts_service.dart';

class CommunicationService {
  final ContactsService _contactsService = ContactsService();

  /// Resolves a contact name or raw phone number down to a dialable number.
  ///
  /// Tries, in order:
  ///   1. An exact/substring contact match (fast path).
  ///   2. A fuzzy contact match (exact → contains → word-starts-with).
  ///   3. Treating the input itself as a phone number if it looks like one.
  Future<_ResolvedNumber?> _resolveNumber({
    String? contactName,
    String? phoneNumber,
  }) async {
    if (phoneNumber != null && phoneNumber.trim().isNotEmpty) {
      return _ResolvedNumber(_normalizeNumber(phoneNumber), null);
    }

    if (contactName == null || contactName.trim().isEmpty) return null;
    final trimmedName = contactName.trim();

    // 1. Direct lookup (searchContacts + first match).
    final direct = await _contactsService.getPhoneNumber(trimmedName);
    if (direct != null && direct.isNotEmpty) {
      return _ResolvedNumber(_normalizeNumber(direct), trimmedName);
    }

    // 2. Fuzzy fallback: exact -> contains -> word-starts-with.
    final fuzzyMatch = await _contactsService.findBestMatch(trimmedName);
    if (fuzzyMatch != null && fuzzyMatch.phones.isNotEmpty) {
      return _ResolvedNumber(
        _normalizeNumber(fuzzyMatch.phones.first.number),
        fuzzyMatch.displayName,
      );
    }

    // 3. Maybe the "name" the caller passed was actually already a number
    // (e.g. pasted digits landed in contact_name by mistake).
    if (_looksLikePhoneNumber(trimmedName)) {
      return _ResolvedNumber(_normalizeNumber(trimmedName), null);
    }

    return null;
  }

  static bool _looksLikePhoneNumber(String value) {
    final digitsOnly = value.replaceAll(RegExp(r'[\s()\-.+]'), '');
    return digitsOnly.isNotEmpty &&
        digitsOnly.length >= 5 &&
        RegExp(r'^\d+$').hasMatch(digitsOnly);
  }

  static String _normalizeNumber(String value) {
    return value.trim();
  }

  /// Make a phone call. Can accept a name or number.
  ///
  /// This places the call for real: it requests the `CALL_PHONE` runtime
  /// permission if needed, then fires a native `ACTION_CALL` intent (not
  /// `ACTION_DIAL`/`tel:`, which merely opens the dialer and waits for the
  /// user to tap the call button themselves). Only falls back to opening the
  /// dialer if the user explicitly denies the permission.
  Future<String> makeCall({String? contactName, String? phoneNumber}) async {
    final resolved = await _resolveNumber(
      contactName: contactName,
      phoneNumber: phoneNumber,
    );

    if (resolved == null) {
      if (contactName != null) {
        return 'Could not find a contact matching "$contactName" and it '
            'doesn\'t look like a phone number either. Check the name/number and try again.';
      }
      return 'No phone number provided.';
    }

    final number = resolved.number;
    final resolvedName = resolved.contactName;

    if (number.isEmpty) {
      return 'No phone number provided.';
    }

    // CALL_PHONE is a dangerous permission — Android requires an explicit
    // runtime grant even though it's declared in the manifest. Without this
    // check, ACTION_CALL either silently no-ops or throws, and the app
    // would incorrectly report success while nothing was actually dialed.
    var status = await Permission.phone.status;
    if (!status.isGranted) {
      status = await Permission.phone.request();
    }

    if (status.isGranted) {
      try {
        final intent = AndroidIntent(
          action: 'android.intent.action.CALL',
          data: 'tel:${Uri.encodeComponent(number)}',
          flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
        );
        await intent.launch();
        return 'Calling $number${resolvedName != null ? ' ($resolvedName)' : ''}...';
      } catch (e) {
        return 'Could not place the call to $number: $e';
      }
    }

    // Permission denied — fall back to opening the dialer pre-filled with
    // the number so the user can tap the call button manually.
    try {
      final dialIntent = AndroidIntent(
        action: 'android.intent.action.DIAL',
        data: 'tel:${Uri.encodeComponent(number)}',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await dialIntent.launch();
      return 'Call permission was denied, so I opened the dialer with '
          '$number${resolvedName != null ? ' ($resolvedName)' : ''} ready — tap call to connect.';
    } catch (_) {
      try {
        final uri = Uri(scheme: 'tel', path: number);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
          return 'Call permission was denied, so I opened the dialer for '
              '$number${resolvedName != null ? ' ($resolvedName)' : ''} — tap call to connect.';
        }
      } catch (_) {}
      return 'Call permission was denied and the dialer could not be opened for $number.';
    }
  }

  /// Send an SMS. Can accept a name or number.
  Future<String> sendSms({
    String? contactName,
    String? phoneNumber,
    required String message,
  }) async {
    final resolved = await _resolveNumber(
      contactName: contactName,
      phoneNumber: phoneNumber,
    );

    if (resolved == null) {
      if (contactName != null) {
        return 'Could not find a contact matching "$contactName".';
      }
      return 'No phone number provided.';
    }

    final number = resolved.number;
    final resolvedName = resolved.contactName;

    if (number.isEmpty) {
      return 'No phone number provided.';
    }

    try {
      final uri = Uri(
        scheme: 'sms',
        path: number,
        queryParameters: {'body': message},
      );
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        return 'Opening SMS to $number${resolvedName != null ? ' ($resolvedName)' : ''} with message: "$message"';
      }
      return 'Cannot send SMS on this device.';
    } catch (e) {
      return 'Error sending SMS: $e';
    }
  }

  /// Send an email
  Future<String> sendEmail({
    required String to,
    String? subject,
    String? body,
  }) async {
    try {
      final uri = Uri(
        scheme: 'mailto',
        path: to,
        queryParameters: {
          if (subject != null) 'subject': subject,
          if (body != null) 'body': body,
        },
      );
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        return 'Opening email to $to';
      }
      return 'Cannot send email on this device.';
    } catch (e) {
      return 'Error sending email: $e';
    }
  }
}

class _ResolvedNumber {
  final String number;
  final String? contactName;
  const _ResolvedNumber(this.number, this.contactName);
}
