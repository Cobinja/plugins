// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:platform/platform.dart';

import 'common/core.dart';
import 'common/gradle.dart';
import 'common/package_looping_command.dart';
import 'common/plugin_utils.dart';
import 'common/process_runner.dart';
import 'common/xcode.dart';

const String _unitTestFlag = 'unit';
const String _integrationTestFlag = 'integration';

const String _iosDestinationFlag = 'ios-destination';

const int _exitNoIosSimulators = 3;

/// The command to run native tests for plugins:
/// - iOS and macOS: XCTests (XCUnitTest and XCUITest) in plugins.
class NativeTestCommand extends PackageLoopingCommand {
  /// Creates an instance of the test command.
  NativeTestCommand(
    Directory packagesDir, {
    ProcessRunner processRunner = const ProcessRunner(),
    Platform platform = const LocalPlatform(),
  })  : _xcode = Xcode(processRunner: processRunner, log: true),
        super(packagesDir, processRunner: processRunner, platform: platform) {
    argParser.addOption(
      _iosDestinationFlag,
      help: 'Specify the destination when running iOS tests.\n'
          'This is passed to the `-destination` argument in the xcodebuild command.\n'
          'See https://developer.apple.com/library/archive/technotes/tn2339/_index.html#//apple_ref/doc/uid/DTS40014588-CH1-UNIT '
          'for details on how to specify the destination.',
    );
    argParser.addFlag(kPlatformAndroid, help: 'Runs Android tests');
    argParser.addFlag(kPlatformIos, help: 'Runs iOS tests');
    argParser.addFlag(kPlatformMacos, help: 'Runs macOS tests');

    // By default, both unit tests and integration tests are run, but provide
    // flags to disable one or the other.
    argParser.addFlag(_unitTestFlag,
        help: 'Runs native unit tests', defaultsTo: true);
    argParser.addFlag(_integrationTestFlag,
        help: 'Runs native integration (UI) tests', defaultsTo: true);
  }

  // The device destination flags for iOS tests.
  List<String> _iosDestinationFlags = <String>[];

  final Xcode _xcode;

  @override
  final String name = 'native-test';

  @override
  final String description = '''
Runs native unit tests and native integration tests.

Currently supported platforms:
- Android (unit tests only)
- iOS: requires 'xcrun' to be in your path.
- macOS: requires 'xcrun' to be in your path.

The example app(s) must be built for all targeted platforms before running
this command.
''';

  Map<String, _PlatformDetails> _platforms = <String, _PlatformDetails>{};

  List<String> _requestedPlatforms = <String>[];

  @override
  Future<void> initializeRun() async {
    _platforms = <String, _PlatformDetails>{
      kPlatformAndroid: _PlatformDetails('Android', _testAndroid),
      kPlatformIos: _PlatformDetails('iOS', _testIos),
      kPlatformMacos: _PlatformDetails('macOS', _testMacOS),
    };
    _requestedPlatforms = _platforms.keys
        .where((String platform) => getBoolArg(platform))
        .toList();
    _requestedPlatforms.sort();

    if (_requestedPlatforms.isEmpty) {
      printError('At least one platform flag must be provided.');
      throw ToolExit(exitInvalidArguments);
    }

    if (!(getBoolArg(_unitTestFlag) || getBoolArg(_integrationTestFlag))) {
      printError('At least one test type must be enabled.');
      throw ToolExit(exitInvalidArguments);
    }

    // iOS-specific run-level state.
    if (_requestedPlatforms.contains('ios')) {
      String destination = getStringArg(_iosDestinationFlag);
      if (destination.isEmpty) {
        final String? simulatorId =
            await _xcode.findBestAvailableIphoneSimulator();
        if (simulatorId == null) {
          printError('Cannot find any available iOS simulators.');
          throw ToolExit(_exitNoIosSimulators);
        }
        destination = 'id=$simulatorId';
      }
      _iosDestinationFlags = <String>[
        '-destination',
        destination,
      ];
    }
  }

  @override
  Future<PackageResult> runForPackage(Directory package) async {
    final List<String> testPlatforms = <String>[];
    for (final String platform in _requestedPlatforms) {
      if (pluginSupportsPlatform(platform, package,
          requiredMode: PlatformSupport.inline)) {
        testPlatforms.add(platform);
      } else {
        print('No implementation for ${_platforms[platform]!.label}.');
      }
    }

    if (testPlatforms.isEmpty) {
      return PackageResult.skip('Not implemented for target platform(s).');
    }

    final _TestMode mode = _TestMode(
      unit: getBoolArg(_unitTestFlag),
      integration: getBoolArg(_integrationTestFlag),
    );

    bool ranTests = false;
    bool failed = false;
    final List<String> failureMessages = <String>[];
    for (final String platform in testPlatforms) {
      final _PlatformDetails platformInfo = _platforms[platform]!;
      print('Running tests for ${platformInfo.label}...');
      print('----------------------------------------');
      final _PlatformResult result =
          await platformInfo.testFunction(package, mode);
      ranTests |= result.state != RunState.skipped;
      if (result.state == RunState.failed) {
        failed = true;

        final String? error = result.error;
        // Only provide the failing platforms in the failure details if testing
        // multiple platforms, otherwise it's just noise.
        if (_requestedPlatforms.length > 1) {
          failureMessages.add(error != null
              ? '${platformInfo.label}: $error'
              : platformInfo.label);
        } else if (error != null) {
          // If there's only one platform, only provide error details in the
          // summary if the platform returned a message.
          failureMessages.add(error);
        }
      }
    }

    if (!ranTests) {
      return PackageResult.skip('No tests found.');
    }
    return failed
        ? PackageResult.fail(failureMessages)
        : PackageResult.success();
  }

  Future<_PlatformResult> _testAndroid(Directory plugin, _TestMode mode) async {
    bool exampleHasUnitTests(Directory example) {
      return example
              .childDirectory('android')
              .childDirectory('app')
              .childDirectory('src')
              .childDirectory('test')
              .existsSync() ||
          example.parent
              .childDirectory('android')
              .childDirectory('src')
              .childDirectory('test')
              .existsSync();
    }

    bool exampleHasNativeIntegrationTests(Directory example) {
      final Directory integrationTestDirectory = example
          .childDirectory('android')
          .childDirectory('app')
          .childDirectory('src')
          .childDirectory('androidTest');
      // There are two types of integration tests that can be in the androidTest
      // directory:
      // - FlutterTestRunner.class tests, which bridge to Dart integration tests
      // - Purely native tests
      // Only the latter is supported by this command; the former will hang if
      // run here because they will wait for a Dart call that will never come.
      //
      // This repository uses a convention of putting the former in a
      // *ActivityTest.java file, so ignore that file when checking for tests.
      // Also ignore DartIntegrationTest.java, which defines the annotation used
      // below for filtering the former out when running tests.
      //
      // If those are the only files, then there are no tests to run here.
      return integrationTestDirectory.existsSync() &&
          integrationTestDirectory
              .listSync(recursive: true)
              .whereType<File>()
              .any((File file) {
            final String basename = file.basename;
            return !basename.endsWith('ActivityTest.java') &&
                basename != 'DartIntegrationTest.java';
          });
    }

    final Iterable<Directory> examples = getExamplesForPlugin(plugin);

    bool ranTests = false;
    bool failed = false;
    bool hasMissingBuild = false;
    for (final Directory example in examples) {
      final bool hasUnitTests = exampleHasUnitTests(example);
      final bool hasIntegrationTests =
          exampleHasNativeIntegrationTests(example);

      if (mode.unit && !hasUnitTests) {
        _printNoExampleTestsMessage(example, 'Android unit');
      }
      if (mode.integration && !hasIntegrationTests) {
        _printNoExampleTestsMessage(example, 'Android integration');
      }

      final bool runUnitTests = mode.unit && hasUnitTests;
      final bool runIntegrationTests = mode.integration && hasIntegrationTests;
      if (!runUnitTests && !runIntegrationTests) {
        continue;
      }

      final String exampleName = getPackageDescription(example);
      _printRunningExampleTestsMessage(example, 'Android');

      final GradleProject project = GradleProject(
        example,
        processRunner: processRunner,
        platform: platform,
      );
      if (!project.isConfigured()) {
        printError('ERROR: Run "flutter build apk" on $exampleName, or run '
            'this tool\'s "build-examples --apk" command, '
            'before executing tests.');
        failed = true;
        hasMissingBuild = true;
        continue;
      }

      if (runUnitTests) {
        print('Running unit tests...');
        final int exitCode = await project.runCommand('testDebugUnitTest');
        if (exitCode != 0) {
          printError('$exampleName unit tests failed.');
          failed = true;
        }
        ranTests = true;
      }

      if (runIntegrationTests) {
        // FlutterTestRunner-based tests will hang forever if run in a normal
        // app build, since they wait for a Dart call from integration_test that
        // will never come. Those tests have an extra annotation to allow
        // filtering them out.
        const String filter =
            'notAnnotation=io.flutter.plugins.DartIntegrationTest';

        print('Running integration tests...');
        final int exitCode = await project.runCommand(
          'app:connectedAndroidTest',
          arguments: <String>[
            '-Pandroid.testInstrumentationRunnerArguments.$filter',
          ],
        );
        if (exitCode != 0) {
          printError('$exampleName integration tests failed.');
          failed = true;
        }
        ranTests = true;
      }
    }

    if (failed) {
      return _PlatformResult(RunState.failed,
          error: hasMissingBuild
              ? 'Examples must be built before testing.'
              : null);
    }
    if (!ranTests) {
      return _PlatformResult(RunState.skipped);
    }
    return _PlatformResult(RunState.succeeded);
  }

  Future<_PlatformResult> _testIos(Directory plugin, _TestMode mode) {
    return _runXcodeTests(plugin, 'iOS', mode,
        extraFlags: _iosDestinationFlags);
  }

  Future<_PlatformResult> _testMacOS(Directory plugin, _TestMode mode) {
    return _runXcodeTests(plugin, 'macOS', mode);
  }

  /// Runs all applicable tests for [plugin], printing status and returning
  /// the test result.
  ///
  /// The tests targets must be added to the Xcode project of the example app,
  /// usually at "example/{ios,macos}/Runner.xcworkspace".
  Future<_PlatformResult> _runXcodeTests(
    Directory plugin,
    String platform,
    _TestMode mode, {
    List<String> extraFlags = const <String>[],
  }) async {
    String? testTarget;
    if (mode.unitOnly) {
      testTarget = 'RunnerTests';
    } else if (mode.integrationOnly) {
      testTarget = 'RunnerUITests';
    }

    // Assume skipped until at least one test has run.
    RunState overallResult = RunState.skipped;
    for (final Directory example in getExamplesForPlugin(plugin)) {
      final String exampleName = getPackageDescription(example);

      if (testTarget != null) {
        final Directory project = example
            .childDirectory(platform.toLowerCase())
            .childDirectory('Runner.xcodeproj');
        final bool? hasTarget =
            await _xcode.projectHasTarget(project, testTarget);
        if (hasTarget == null) {
          printError('Unable to check targets for $exampleName.');
          overallResult = RunState.failed;
          continue;
        } else if (!hasTarget) {
          print('No "$testTarget" target in $exampleName; skipping.');
          continue;
        }
      }

      _printRunningExampleTestsMessage(example, platform);
      final int exitCode = await _xcode.runXcodeBuild(
        example,
        actions: <String>['test'],
        workspace: '${platform.toLowerCase()}/Runner.xcworkspace',
        scheme: 'Runner',
        configuration: 'Debug',
        extraFlags: <String>[
          if (testTarget != null) '-only-testing:$testTarget',
          ...extraFlags,
          'GCC_TREAT_WARNINGS_AS_ERRORS=YES',
        ],
      );

      // The exit code from 'xcodebuild test' when there are no tests.
      const int _xcodebuildNoTestExitCode = 66;
      switch (exitCode) {
        case _xcodebuildNoTestExitCode:
          _printNoExampleTestsMessage(example, platform);
          continue;
        case 0:
          printSuccess('Successfully ran $platform xctest for $exampleName');
          // If this is the first test, assume success until something fails.
          if (overallResult == RunState.skipped) {
            overallResult = RunState.succeeded;
          }
          break;
        default:
          // Any failure means a failure overall.
          overallResult = RunState.failed;
          break;
      }
    }
    return _PlatformResult(overallResult);
  }

  /// Prints a standard format message indicating that [platform] tests for
  /// [plugin]'s [example] are about to be run.
  void _printRunningExampleTestsMessage(Directory example, String platform) {
    print('Running $platform tests for ${getPackageDescription(example)}...');
  }

  /// Prints a standard format message indicating that no tests were found for
  /// [plugin]'s [example] for [platform].
  void _printNoExampleTestsMessage(Directory example, String platform) {
    print('No $platform tests found for ${getPackageDescription(example)}');
  }
}

// The type for a function that takes a plugin directory and runs its native
// tests for a specific platform.
typedef _TestFunction = Future<_PlatformResult> Function(Directory, _TestMode);

/// A collection of information related to a specific platform.
class _PlatformDetails {
  const _PlatformDetails(
    this.label,
    this.testFunction,
  );

  /// The name to use in output.
  final String label;

  /// The function to call to run tests.
  final _TestFunction testFunction;
}

/// Enabled state for different test types.
class _TestMode {
  const _TestMode({required this.unit, required this.integration});

  final bool unit;
  final bool integration;

  bool get integrationOnly => integration && !unit;
  bool get unitOnly => unit && !integration;
}

/// The result of running a single platform's tests.
class _PlatformResult {
  _PlatformResult(this.state, {this.error});

  /// The overall state of the platform's tests. This should be:
  /// - failed if any tests failed.
  /// - succeeded if at least one test ran, and all tests passed.
  /// - skipped if no tests ran.
  final RunState state;

  /// An optional error string to include in the summary for this platform.
  ///
  /// Ignored unless [state] is `failed`.
  final String? error;
}