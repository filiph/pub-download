// Copyright (c) 2016, <your name>. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

/// Fetches new pub packages and builds a "log" of new package versions.
///
/// Each package is categorized with semver version (major, minor, patch)
/// and with only-google, google or non-google.
library pub_download;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite/sqlite.dart';

main(List<String> arguments) async {
  print('Fetching $startingUrl');

  final HttpClient client = new HttpClient();
  final Database db = new Database(databaseFile);

  bool firstRun = arguments.contains("first-run");
  if (firstRun) {
    print("First run");
    _dropTable(db);
  }

  await _setupTableIfMissing(db);

  int urlsCount = 0;
  String nextUrl = startingUrl;

  while (urlsCount < maxUrls) {
    var indexJson = await fetchJson(client, nextUrl);

    for (String packageUrl in indexJson['packages']) {
      urlsCount++;
      if (urlsCount >= maxUrls) {
        break;
      }

      var packageJson = await fetchJson(client, packageUrl);
      var package = new PackageInfo.fromJson(packageJson);
      print(package);

      var alreadyLatest = await _checkIfLatestVersionRecordExists(package, db);
      if (alreadyLatest) {
        print("- package record already exists");
        continue;
      }

      var record;
      if (firstRun) {
        record = new Record.historical(package);
      } else {
        record = new Record.now(package);
      }
      await _insert(record, db);
    }

    nextUrl = indexJson['next'];
    if (nextUrl == null) break;
  }

  db.close();
  client.close();
}

const String databaseFile = 'pub_download.db';
const String databaseTable = 'log';
const int maxUrls = 100;
const String startingUrl = 'https://pub.dartlang.org/packages.json';

const String historicalTimestamp = "1970-01-01T00:00:00.000";

Future<Map<String, dynamic>> fetchJson(HttpClient client, String url) async {
  var request = await client.getUrl(Uri.parse(url));
  var response = await request.close();
  var data = await response.transform(UTF8.decoder);
  var json = await data.transform(JSON.decoder).first as Map<String, dynamic>;
  return json;
}

Future<bool> _checkIfLatestVersionRecordExists(
    PackageInfo package, Database db) async {
  final int count = (await db.query(
          "SELECT COUNT(*) AS count FROM $databaseTable "
          "WHERE name=? AND version=?",
          params: [package.name, package.latestVersion]).first)
      .count;
  return count >= 1;
}

_insert(Record record, Database db) async {
  await db
      .execute('INSERT INTO $databaseTable VALUES (?, ?, ?, ?, ?)', params: [
    record.info.name,
    record.info.latestVersion,
    stringifyVersionLevel(record.info.latestVersionLevel),
    stringifyInternalness(record.info.internalness),
    record.timestamp.toIso8601String()
  ]);
}

_dropTable(Database db) async {
  await db.execute('DROP TABLE $databaseTable');
}

_setupTableIfMissing(Database db) async {
  final int count = (await db
          .query("SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type='table' AND name='$databaseTable'")
          .first)
      .count;
  if (count > 0) return;
  print("Creating table $databaseTable");
  await db.execute('CREATE TABLE $databaseTable (name text, version text, '
      'version_level text, internalness text, accessed text)');
}

enum Internalness { googleOnly, googlePartially, thirdParty }

String stringifyInternalness(Internalness value) {
  switch (value) {
    case Internalness.googleOnly:
      return "GOOGLE_ONLY";
    case Internalness.googlePartially:
      return "GOOGLE_PARTIALLY";
    case Internalness.thirdParty:
      return "THIRD_PARTY";
  }
}

class PackageInfo {
  final String name;
  final List<String> uploaders;
  final List<String> versions;

  PackageInfo(this.name, this.uploaders, this.versions) {
    assert(name != null);
    assert(uploaders != null);
    assert(versions != null);
  }

  PackageInfo.fromJson(Map<String, dynamic> json)
      : this(json["name"], json["uploaders"], json["versions"]);

  Internalness get internalness {
    var googlers = uploaders.where((email) => email.contains("@google.com"));
    var googlersCount = googlers.length;
    if (googlersCount == 0) {
      return Internalness.thirdParty;
    } else if (googlersCount == uploaders.length) {
      return Internalness.googleOnly;
    } else {
      return Internalness.googlePartially;
    }
  }

  String get latestVersion => versions.last;

  VersionLevel get latestVersionLevel {
    List<String> levels = latestVersion.split(".");
    if (levels.length != 3) {
      print("Weird semver version: $latestVersion. "
          "Assuming VersionLevel.patch");
      return VersionLevel.patch;
    }
    if (!levels[0].startsWith('0')) {
      return VersionLevel.major;
    } else if (!levels[1].startsWith('0')) {
      return VersionLevel.minor;
    } else {
      return VersionLevel.patch;
    }
  }

  toString() => "$name ($latestVersion ${stringifyInternalness(internalness)})";
}

class Record {
  PackageInfo info;
  DateTime timestamp;

  Record.now(PackageInfo info) : this._(info, new DateTime.now());

  Record._(this.info, this.timestamp);

  Record.historical(PackageInfo info) : this._(info, new DateTime(1970));
}

enum VersionLevel { major, minor, patch }

String stringifyVersionLevel(VersionLevel value) {
  switch (value) {
    case VersionLevel.major:
      return "MAJOR";
    case VersionLevel.minor:
      return "MINOR";
    case VersionLevel.patch:
      return "PATCH";
  }
}
