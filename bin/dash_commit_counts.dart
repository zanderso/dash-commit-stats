// Copyright 2025 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:args/args.dart';
import 'package:github/github.dart' as g;

// Usage:
//
// $ dart bin/dash_commit_counts.dart -c config.json -o output.jsonl
//
// Pass a config.json file using the -c option to specify which commits to pull.
//
// {
//     "token": "Your GitHub token",
//     "since": "2026-05-21",
//     "until": "2026-05-27",
//     "repos": [
//         "flutter/flutter",
//         ...
//     ],
//     "bots": [
//         "gemini-code-assist[bot]",
//         ...
//     ]
// }

ArgParser buildParser() {
  return ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Show additional command output.',
    )
    ..addOption(
      'config',
      abbr: 'c',
      help: 'Path of the configuration file.',
      mandatory: true,
    )
    ..addOption(
      'output',
      abbr: 'o',
      help: 'Where to write raw commit json data',
      mandatory: true,
    );
}

class Config {
  Config._({
    required this.token,
    required this.repos,
    required this.bots,
    required this.since,
    required this.until,
  });

  static (Config?, String?) fromFile(String path) {
    final io.File configFile = io.File(path);
    final Map<String, dynamic> configData;
    try {
      configData = json.decode(configFile.readAsStringSync());
    } on FormatException catch (e) {
      return (null, '$path is not valid json: $e');
    }

    if (configData[tokenKey] == null ||
        configData[tokenKey] is! String ||
        (configData[tokenKey] as String).isEmpty) {
      return (null, '"token" field must be a non-empty string.');
    }
    final String token = configData['token'] as String;

    if (configData[sinceKey] == null ||
        configData[sinceKey] is! String ||
        (configData[sinceKey] as String).isEmpty) {
      return (null, '"since" field must be a non-empty string.');
    }
    final String sinceStr = configData[sinceKey] as String;
    final DateTime since;
    try {
      since = DateTime.parse(sinceStr);
    } on FormatException catch (e) {
      return (null, '$sinceStr is not a valid date string: $e');
    }

    if (configData[untilKey] == null ||
        configData[untilKey] is! String ||
        (configData[untilKey] as String).isEmpty) {
      return (null, '"until" field must be a non-empty string.');
    }
    final String untilStr = configData[untilKey] as String;
    final DateTime until;
    try {
      until = DateTime.parse(untilStr);
    } on FormatException catch (e) {
      return (null, '$untilStr is not a valid date string: $e');
    }
  
    if (configData[reposKey] == null ||
        configData[reposKey] is! List<dynamic> ||
        (configData[reposKey] as List<dynamic>).isEmpty) {
      return (null, '"repos" field must be a non-empty list of strings.');
    }
    final List<String> repos = (configData[reposKey] as List<dynamic>).cast<String>();
  
    if (configData[botsKey] == null ||
        configData[botsKey] is! List<dynamic> ||
        (configData[botsKey] as List<dynamic>).isEmpty) {
      return (null, '"bots" field must be a non-empty list of strings.');
    }
    final List<String> bots = (configData[botsKey] as List<dynamic>).cast<String>();
  
    return (Config._(
      token: token,
      since: since,
      until: until,
      repos: repos,
      bots: bots,
    ), null);
  }

  final String token;
  final List<String> repos;
  final List<String> bots;
  final DateTime since;
  final DateTime until;

  static const String tokenKey = 'token';
  static const String sinceKey = 'since';
  static const String untilKey = 'until';
  static const String reposKey = 'repos';
  static const String botsKey = 'bots';

  @override
  String toString() {
    return 'Config($token, $repos, $bots, $since, $until)';
  }
}

void printUsage(ArgParser argParser) {
  print('Usage: dart repo_analysis.dart <flags> [arguments]');
  print(argParser.usage);
}

bool gVerbose = false;

void main(List<String> arguments) async {
  final ArgParser argParser = buildParser();
  try {
    final ArgResults results = argParser.parse(arguments);

    // Process the parsed arguments.
    if (results.flag('help')) {
      printUsage(argParser);
      return;
    }
    if (results.flag('verbose')) {
      gVerbose = true;
    }

    if (gVerbose) {
      print('[VERBOSE] All arguments: ${results.arguments}');
    }

    final Config? config;
    switch (Config.fromFile(results.option('config') as String)) {
      case (_, String msg): {
        print(msg);
        print('');
        printUsage(argParser);
        io.exitCode = 1;
        return;
      }
      case (Config c, _): {
        config = c;
      }
      default: {
        config = null;
      }
    }

    if (gVerbose) {
      print(config);
    }

    final List<g.RepositoryCommit> commits = await downloadCommitData(config!);

    if (gVerbose) {
      print('[VERBOSE] Done downloading commit data.');
    }

    if (commits.isEmpty) {
      print('No commits found!');
      io.exitCode = 1;
      return;
    }

    final rawOutputJson = io.File(results.option('output') as String);
    writeCommits(commits, rawOutputJson);
  } on FormatException catch (e) {
    // Print usage information if an invalid argument was provided.
    print(e.message);
    print('');
    printUsage(argParser);
  }
}

void writeCommits(
  List<g.RepositoryCommit> commits,
  io.File rawOutputJson,
) {
  if (gVerbose) {
    print('[VERBOSE] Writing out raw commit data.');
  }

  for (final g.RepositoryCommit commit in commits) {
    final StringBuffer b = StringBuffer();
    b.writeln(jsonEncode(commit.toJson()));
    rawOutputJson.writeAsStringSync(b.toString(), flush: true, mode: io.FileMode.append);
  }
}

Future<T> callWithRetries<T>(
  // ignore: body_might_complete_normally
  Future<T> Function() f, {
  int retries = 5,
}) async {
  int retryCount = 0;
  while (retryCount < retries) {
    try {
      return await f();
    } catch (e) {
      retryCount += 1;
      if (retryCount >= retries) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  throw Error();
}

// Do not exceed 5000 requests in an hour.
Future<void> pauseForRateLimit(
  g.GitHub github, [
  int? remainingRequests,
]) async {
  final int? total = github.rateLimitLimit;
  final int? remainingQuota = github.rateLimitRemaining;
  final DateTime? reset = github.rateLimitReset;

  // We won't be able to figure this out without this data, so
  // don't wait. Maybe the data will show up before the next
  // request.
  if (total == null || remainingQuota == null || reset == null) {
    return;
  }

  // If the remaining requests are fewer than the remaining quota
  // then don't wait.
  if (remainingRequests != null && remainingRequests < remainingQuota) {
    return;
  }

  final Duration timeUntilReset = reset.difference(DateTime.now());
  if (timeUntilReset.isNegative) {
    // If the time until reset is in the past, then don't wait.
    return;
  }

  // Don't exceed `remaining` requests within the `timeUntilReset`
  // duration.
  final int millis = timeUntilReset.inMilliseconds;
  // Evenly divide up the remain time among the remaining quota.
  final double delayInMillis = remainingQuota == 0
      ? millis.toDouble()
      : millis / remainingQuota;
  if (delayInMillis < 1.0) {
    // If the delay is less than a millisecond, then don't wait.
    return;
  }

  print(
    'Rate limit: Waiting ${delayInMillis.ceil()} ms. '
    '($remainingQuota/$total) reset in: $timeUntilReset',
  );
  return Future.delayed(Duration(milliseconds: delayInMillis.ceil()));
}

Future<g.RepositoryCommit?> getCommit(
  g.RepositoriesService service,
  String repo,
  String? sha, {
  int? remainingRequests,
}) async {
  if (sha == null) {
    return null;
  }
  try {
    return await callWithRetries(() async {
      final g.RepositorySlug slug = g.RepositorySlug.full(repo);
      await pauseForRateLimit(service.github, remainingRequests);
      if (gVerbose) {
        print('[VERBOSE] getting $sha from $repo');
      }
      return service.getCommit(slug, sha);
    }, retries: 5);
  } catch (e) {
    print('Failed to get commit: Error: $e');
    return null;
  }
}

Future<List<g.RepositoryCommit>> getCommits(
  g.RepositoriesService service,
  String repo,
  DateTime after, 
  DateTime before, {
  int? remainingRequests,
}) async {
  return callWithRetries(() async {
    final List<g.RepositoryCommit> commits = <g.RepositoryCommit>[];
    final g.RepositorySlug slug = g.RepositorySlug.full(repo);
    await pauseForRateLimit(service.github, remainingRequests);
    if (gVerbose) {
      print('[VERBOSE] Listing commits of $repo');
    }
    final StreamSubscription<g.RepositoryCommit> sub = service
        .listCommits(slug, since: after, until: before)
        .listen((g.RepositoryCommit commit) async {
          commits.add(commit);
        });
    try {
      await sub.asFuture();
      if (gVerbose) {
        print('[VERBOSE] commit list stream for $repo completed');
      }
    } catch (e) {
      try {
        await sub.cancel();
      } catch (e) {
        // ignore.
      }
      rethrow;
    }
    return commits;
  }, retries: 5);
}

Future<List<g.RepositoryCommit>> downloadCommitData(Config config) async {
  final g.GitHub github = g.GitHub(
    auth: g.Authentication.withToken(config.token),
  );
  final g.RepositoriesService service = g.RepositoriesService(github);

  // Get all the partial commits for all the repos before requesting the complete data.
  final Map<String, List<g.RepositoryCommit>> partialCommits = {};
  for (final String repo in config.repos) {
    io.stdout.write('Downloading commit data for "$repo"\n');
    try {
      partialCommits[repo] = await getCommits(service, repo, config.since, config.until);
    } catch (e) {
      print('\nFailed to get commits for $repo: Error: $e');
      print(
        '\nrateLimitLimit: ${github.rateLimitLimit} '
        '\nrateLimitRemaining: ${github.rateLimitRemaining} '
        '\nrateLimitReset: ${github.rateLimitReset!.toLocal()}',
      );
      return <g.RepositoryCommit>[];
    }
  }

  final List<g.RepositoryCommit> fullCommits = [];
  final int commitCount = partialCommits.values.fold(0, (c, l) => c + l.length);
  if (gVerbose) {
    print('[VERBOSE] Downloading full data for $commitCount commits');
  }
  for (final String repo in partialCommits.keys) {
    final List<g.RepositoryCommit> repoCommits = partialCommits[repo]!;
    if (gVerbose) {
      print('[VERBOSE] ${commitCount - fullCommits.length} commits remaining.');
    }
    for (final g.RepositoryCommit commit in repoCommits) {
      final int remainingCommits = commitCount - fullCommits.length;
      final g.RepositoryCommit? fullCommit = await getCommit(
        service,
        repo,
        commit.sha,
        remainingRequests: remainingCommits,
      );
      if (fullCommit == null) {
        continue;
      }
      fullCommits.add(fullCommit);
    }
  }

  if (gVerbose) {
    print('[VERBOSE] Got all commit data');
  }

  return fullCommits.where((g.RepositoryCommit commit) {
    final String id = commit.author!.login!;
    return !config.bots.contains(id);
  }).toList();
}
