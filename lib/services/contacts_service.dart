import 'package:flutter_contacts/flutter_contacts.dart';

class ContactsService {
  /// Search contacts by name. Returns formatted results.
  Future<List<Contact>> searchContacts(String query) async {
    // `readonly: true` only asks for READ_CONTACTS (never WRITE_CONTACTS),
    // which is the only Android contacts permission this app declares —
    // requesting write access here would silently fail the whole grant.
    if (!await FlutterContacts.requestPermission(readonly: true)) {
      return [];
    }

    final contacts = await FlutterContacts.getContacts(
      withProperties: true,
      withPhoto: false,
    );

    final lowerQuery = query.toLowerCase();
    return contacts.where((c) {
      return c.displayName.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Get phone number for a contact name. Returns the first match.
  Future<String?> getPhoneNumber(String contactName) async {
    final matches = await searchContacts(contactName);
    if (matches.isEmpty) return null;

    final contact = matches.first;
    if (contact.phones.isEmpty) return null;

    return contact.phones.first.number;
  }

  /// Finds the single best-matching contact for [query] using a layered
  /// fuzzy strategy:
  ///   1. Exact (case-insensitive) full-name match.
  ///   2. Name *contains* the query (or vice-versa).
  ///   3. Any word in the name *starts with* the query.
  ///
  /// Returns `null` if no contacts are found or none match at any tier.
  Future<Contact?> findBestMatch(String query) async {
    if (!await FlutterContacts.requestPermission(readonly: true)) return null;
    if (query.trim().isEmpty) return null;

    final contacts = await FlutterContacts.getContacts(
      withProperties: true,
      withPhoto: false,
    );
    if (contacts.isEmpty) return null;

    final lowerQuery = query.trim().toLowerCase();

    // 1. Exact match.
    for (final contact in contacts) {
      if (contact.displayName.trim().toLowerCase() == lowerQuery) {
        return contact;
      }
    }

    // 2. Contains match (name contains query, or query contains name —
    //    handles both "John" -> "John Smith" and "Jonathan Smith" -> "Jon").
    final containsMatches = contacts.where((c) {
      final name = c.displayName.trim().toLowerCase();
      if (name.isEmpty) return false;
      return name.contains(lowerQuery) || lowerQuery.contains(name);
    }).toList();
    if (containsMatches.isNotEmpty) {
      // Prefer the shortest name — the "tightest" contains match.
      containsMatches.sort(
        (a, b) => a.displayName.length.compareTo(b.displayName.length),
      );
      return containsMatches.first;
    }

    // 3. Word-starts-with match (e.g. "mike" -> "Michael Johnson").
    final startsWithMatches = contacts.where((c) {
      final words = c.displayName.trim().toLowerCase().split(RegExp(r'\s+'));
      return words.any((w) => w.isNotEmpty && w.startsWith(lowerQuery));
    }).toList();
    if (startsWithMatches.isNotEmpty) {
      startsWithMatches.sort(
        (a, b) => a.displayName.length.compareTo(b.displayName.length),
      );
      return startsWithMatches.first;
    }

    return null;
  }

  /// Format contact search results as readable text
  Future<String> searchAndFormat(String query) async {
    final contacts = await searchContacts(query);

    if (contacts.isEmpty) {
      // Fall back to fuzzy match so the AI/router still gets a useful result
      // even if the exact substring search came up empty.
      final fuzzy = await findBestMatch(query);
      if (fuzzy == null) {
        return 'No contacts found matching "$query".';
      }
      final buffer = StringBuffer(
        'No exact matches for "$query", but found a close match:\n',
      );
      buffer.write('• ${fuzzy.displayName}');
      if (fuzzy.phones.isNotEmpty) {
        buffer.write(' - ${fuzzy.phones.first.number}');
      }
      if (fuzzy.emails.isNotEmpty) {
        buffer.write(' - ${fuzzy.emails.first.address}');
      }
      return buffer.toString();
    }

    final buffer = StringBuffer('Found ${contacts.length} contact(s):\n');
    for (final contact in contacts.take(5)) {
      buffer.write('• ${contact.displayName}');
      if (contact.phones.isNotEmpty) {
        buffer.write(' - ${contact.phones.first.number}');
      }
      if (contact.emails.isNotEmpty) {
        buffer.write(' - ${contact.emails.first.address}');
      }
      buffer.writeln();
    }
    if (contacts.length > 5) {
      buffer.writeln('...and ${contacts.length - 5} more');
    }

    return buffer.toString();
  }
}
