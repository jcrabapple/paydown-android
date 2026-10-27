import 'dart:convert';
import 'dart:io';

/// Loads a scrubbed server fixture from docs/fixtures as decoded JSON
/// (List for array payloads, Map for objects).
dynamic fixtures(String name) =>
    jsonDecode(File('docs/fixtures/$name.json').readAsStringSync());
