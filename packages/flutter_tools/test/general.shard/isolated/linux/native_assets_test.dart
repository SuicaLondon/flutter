// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:file_testing/file_testing.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/dart/package_map.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/isolated/native_assets/linux/native_assets.dart';
import 'package:flutter_tools/src/isolated/native_assets/native_assets.dart';
import 'package:native_assets_cli/native_assets_cli_internal.dart'
    hide Target;
import 'package:package_config/package_config_types.dart';

import '../../../src/common.dart';
import '../../../src/context.dart';
import '../../../src/fakes.dart';
import '../fake_native_assets_build_runner.dart';

void main() {
  late FakeProcessManager processManager;
  late Environment environment;
  late Artifacts artifacts;
  late FileSystem fileSystem;
  late BufferLogger logger;
  late Uri projectUri;

  setUp(() {
    processManager = FakeProcessManager.empty();
    logger = BufferLogger.test();
    artifacts = Artifacts.test();
    fileSystem = MemoryFileSystem.test();
    environment = Environment.test(
      fileSystem.currentDirectory,
      inputs: <String, String>{},
      artifacts: artifacts,
      processManager: processManager,
      fileSystem: fileSystem,
      logger: logger,
    );
    environment.buildDir.createSync(recursive: true);
    projectUri = environment.projectDir.uri;
  });

  testUsingContext('dry run with no package config', overrides: <Type, Generator>{
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    expect(
      await dryRunNativeAssetsLinux(
        projectUri: projectUri,
        fileSystem: fileSystem,
        buildRunner: FakeNativeAssetsBuildRunner(
          hasPackageConfigResult: false,
        ),
      ),
      null,
    );
    expect(
      (globals.logger as BufferLogger).traceText,
      contains('No package config found. Skipping native assets compilation.'),
    );
  });

  testUsingContext('build with no package config', overrides: <Type, Generator>{
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    await buildNativeAssetsLinux(
      projectUri: projectUri,
      buildMode: BuildMode.debug,
      fileSystem: fileSystem,
      buildRunner: FakeNativeAssetsBuildRunner(
        hasPackageConfigResult: false,
      ),
    );
    expect(
      (globals.logger as BufferLogger).traceText,
      contains('No package config found. Skipping native assets compilation.'),
    );
  });

  testUsingContext('does not throw if clang not present but no native assets present', overrides: <Type, Generator>{
    FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true),
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    final File packageConfig = environment.projectDir.childFile('.dart_tool/package_config.json');
    await packageConfig.create(recursive: true);
    await buildNativeAssetsLinux(
      projectUri: projectUri,
      buildMode: BuildMode.debug,
      fileSystem: fileSystem,
      buildRunner: _BuildRunnerWithoutClang(),
    );
    expect(
      (globals.logger as BufferLogger).traceText,
      isNot(contains('Building native assets for ')),
    );
  });

  testUsingContext('dry run for multiple OSes with no package config', overrides: <Type, Generator>{
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    await dryRunNativeAssetsMultipleOSes(
      projectUri: projectUri,
      fileSystem: fileSystem,
      targetPlatforms: <TargetPlatform>[
        TargetPlatform.darwin,
        TargetPlatform.ios,
      ],
      buildRunner: FakeNativeAssetsBuildRunner(
        hasPackageConfigResult: false,
      ),
    );
    expect(
      (globals.logger as BufferLogger).traceText,
      contains('No package config found. Skipping native assets compilation.'),
    );
  });

  testUsingContext('dry run with assets but not enabled', overrides: <Type, Generator>{
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    final File packageConfig = environment.projectDir.childFile('.dart_tool/package_config.json');
    await packageConfig.parent.create();
    await packageConfig.create();
    expect(
      () => dryRunNativeAssetsLinux(
        projectUri: projectUri,
        fileSystem: fileSystem,
        buildRunner: FakeNativeAssetsBuildRunner(
          packagesWithNativeAssetsResult: <Package>[
            Package('bar', projectUri),
          ],
        ),
      ),
      throwsToolExit(
        message: 'Package(s) bar require the native assets feature to be enabled. '
            'Enable using `flutter config --enable-native-assets`.',
      ),
    );
  });

  testUsingContext('dry run with assets', overrides: <Type, Generator>{
    FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true),
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    final File packageConfig = environment.projectDir.childFile('.dart_tool/package_config.json');
    await packageConfig.parent.create();
    await packageConfig.create();
    final FakeNativeAssetsBuildRunner buildRunner = FakeNativeAssetsBuildRunner(
      packagesWithNativeAssetsResult: <Package>[
        Package('bar', projectUri),
      ],
      buildDryRunResult: FakeNativeAssetsBuilderResult(
        assets: <AssetImpl>[
          NativeCodeAssetImpl(
            id: 'package:bar/bar.dart',
            linkMode: DynamicLoadingBundledImpl(),
            os: OSImpl.linux,
            architecture: ArchitectureImpl.x64,
            file: Uri.file('libbar.so'),
          ),
          NativeCodeAssetImpl(
            id: 'package:bar/bar.dart',
            linkMode: DynamicLoadingBundledImpl(),
            os: OSImpl.linux,
            architecture: ArchitectureImpl.arm64,
            file: Uri.file('libbar.so'),
          ),
        ],
      ),
    );
    final Uri? nativeAssetsYaml = await dryRunNativeAssetsLinux(
      projectUri: projectUri,
      fileSystem: fileSystem,
      buildRunner: buildRunner,
    );
    expect(
      (globals.logger as BufferLogger).traceText,
      stringContainsInOrder(<String>[
        'Dry running native assets for linux.',
        'Dry running native assets for linux done.',
      ]),
    );
    expect(
      nativeAssetsYaml,
      projectUri.resolve('build/native_assets/linux/native_assets.yaml'),
    );
    expect(
      await fileSystem.file(nativeAssetsYaml).readAsString(),
      contains('package:bar/bar.dart'),
    );
    expect(buildRunner.buildDryRunInvocations, 1);
    expect(buildRunner.linkDryRunInvocations, 0);
  });

  testUsingContext('build with assets but not enabled', overrides: <Type, Generator>{
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    final File packageConfig = environment.projectDir.childFile('.dart_tool/package_config.json');
    await packageConfig.parent.create();
    await packageConfig.create();
    expect(
      () => buildNativeAssetsLinux(
        projectUri: projectUri,
        buildMode: BuildMode.debug,
        fileSystem: fileSystem,
        buildRunner: FakeNativeAssetsBuildRunner(
          packagesWithNativeAssetsResult: <Package>[
            Package('bar', projectUri),
          ],
        ),
      ),
      throwsToolExit(
        message: 'Package(s) bar require the native assets feature to be enabled. '
            'Enable using `flutter config --enable-native-assets`.',
      ),
    );
  });

  testUsingContext('build no assets', overrides: <Type, Generator>{
    FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true),
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    final File packageConfig = environment.projectDir.childFile('.dart_tool/package_config.json');
    await packageConfig.parent.create();
    await packageConfig.create();
    final (Uri? nativeAssetsYaml, _) = await buildNativeAssetsLinux(
      targetPlatform: TargetPlatform.linux_x64,
      projectUri: projectUri,
      buildMode: BuildMode.debug,
      fileSystem: fileSystem,
      buildRunner: FakeNativeAssetsBuildRunner(
        packagesWithNativeAssetsResult: <Package>[
          Package('bar', projectUri),
        ],
      ),
    );
    expect(
      nativeAssetsYaml,
      projectUri.resolve('build/native_assets/linux/native_assets.yaml'),
    );
    expect(
      await fileSystem.file(nativeAssetsYaml).readAsString(),
      isNot(contains('package:bar/bar.dart')),
    );
    expect(
      environment.projectDir
          .childDirectory('build')
          .childDirectory('native_assets')
          .childDirectory('linux'),
      exists,
    );
  });

  for (final bool flutterTester in <bool>[false, true]) {
    String testName = '';
    if (flutterTester) {
      testName += ' flutter tester';
    }
    for (final BuildMode buildMode in <BuildMode>[
      BuildMode.debug,
      BuildMode.release,
    ]) {
      testUsingContext('build with assets $buildMode$testName',
          overrides: <Type, Generator>{
            FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true),
            ProcessManager: () => FakeProcessManager.empty(),
          }, () async {
        final File packageConfig = environment.projectDir
            .childDirectory('.dart_tool')
            .childFile('package_config.json');
        await packageConfig.parent.create();
        await packageConfig.create();
        final File dylibAfterCompiling = fileSystem.file('libbar.so');
        // The mock doesn't create the file, so create it here.
        await dylibAfterCompiling.create();
        final FakeNativeAssetsBuildRunner buildRunner =
            FakeNativeAssetsBuildRunner(
          packagesWithNativeAssetsResult: <Package>[
            Package('bar', projectUri),
          ],
          buildResult: FakeNativeAssetsBuilderResult(
            assets: <AssetImpl>[
              NativeCodeAssetImpl(
                id: 'package:bar/bar.dart',
                linkMode: DynamicLoadingBundledImpl(),
                os: OSImpl.linux,
                architecture: ArchitectureImpl.x64,
                file: dylibAfterCompiling.uri,
              ),
            ],
          ),
        );
        final (Uri? nativeAssetsYaml, _) = await buildNativeAssetsLinux(
          targetPlatform: TargetPlatform.linux_x64,
          projectUri: projectUri,
          buildMode: buildMode,
          fileSystem: fileSystem,
          flutterTester: flutterTester,
          buildRunner: buildRunner,
        );
        expect(
          (globals.logger as BufferLogger).traceText,
          stringContainsInOrder(<String>[
            'Building native assets for linux_x64 $buildMode.',
            'Building native assets for linux_x64 done.',
          ]),
        );
        expect(
          nativeAssetsYaml,
          projectUri.resolve('build/native_assets/linux/native_assets.yaml'),
        );
        expect(
          await fileSystem.file(nativeAssetsYaml).readAsString(),
          stringContainsInOrder(<String>[
            'package:bar/bar.dart',
            if (flutterTester)
              // Tests run on host system, so the have the full path on the system.
              '- ${projectUri.resolve('build/native_assets/linux/libbar.so').toFilePath()}'
            else
              // Apps are a bundle with the dylibs on their dlopen path.
              '- libbar.so',
          ]),
        );
        expect(buildRunner.buildInvocations, 1);
        expect(
          buildRunner.linkInvocations,
          buildMode == BuildMode.release ? 1 : 0,
        );
      });
    }
  }

  testUsingContext('static libs not supported', overrides: <Type, Generator>{
    FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true),
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    final File packageConfig = environment.projectDir.childFile('.dart_tool/package_config.json');
    await packageConfig.parent.create();
    await packageConfig.create();
    expect(
      () => dryRunNativeAssetsLinux(
        projectUri: projectUri,
        fileSystem: fileSystem,
        buildRunner: FakeNativeAssetsBuildRunner(
          packagesWithNativeAssetsResult: <Package>[
            Package('bar', projectUri),
          ],
          buildDryRunResult: FakeNativeAssetsBuilderResult(
            assets: <AssetImpl>[
              NativeCodeAssetImpl(
                id: 'package:bar/bar.dart',
                linkMode: StaticLinkingImpl(),
                os: OSImpl.macOS,
                architecture: ArchitectureImpl.arm64,
                file: Uri.file('bar.a'),
              ),
              NativeCodeAssetImpl(
                id: 'package:bar/bar.dart',
                linkMode: StaticLinkingImpl(),
                os: OSImpl.macOS,
                architecture: ArchitectureImpl.x64,
                file: Uri.file('bar.a'),
              ),
            ],
          ),
        ),
      ),
      throwsToolExit(
        message: 'Native asset(s) package:bar/bar.dart have their link mode set to '
            'static, but this is not yet supported. '
            'For more info see https://github.com/dart-lang/sdk/issues/49418.',
      ),
    );
  });

  testUsingContext('Native assets dry run error', overrides: <Type, Generator>{
    FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true),
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    final File packageConfig =
        environment.projectDir.childFile('.dart_tool/package_config.json');
    await packageConfig.parent.create();
    await packageConfig.create();
    expect(
      () => dryRunNativeAssetsLinux(
        projectUri: projectUri,
        fileSystem: fileSystem,
        buildRunner: FakeNativeAssetsBuildRunner(
          packagesWithNativeAssetsResult: <Package>[
            Package('bar', projectUri),
          ],
          buildDryRunResult: const FakeNativeAssetsBuilderResult(
            success: false,
          ),
        ),
      ),
      throwsToolExit(
        message:
            'Building (dry run) native assets failed. See the logs for more details.',
      ),
    );
  });

  testUsingContext('Native assets build error', overrides: <Type, Generator>{
    FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true),
    ProcessManager: () => FakeProcessManager.empty(),
  }, () async {
    final File packageConfig =
        environment.projectDir.childFile('.dart_tool/package_config.json');
    await packageConfig.parent.create();
    await packageConfig.create();
    expect(
      () => buildNativeAssetsLinux(
        targetPlatform: TargetPlatform.linux_x64,
        projectUri: projectUri,
        buildMode: BuildMode.debug,
        fileSystem: fileSystem,
        yamlParentDirectory: environment.buildDir.uri,
        buildRunner: FakeNativeAssetsBuildRunner(
          packagesWithNativeAssetsResult: <Package>[
            Package('bar', projectUri),
          ],
          buildResult: const FakeNativeAssetsBuilderResult(
            success: false,
          ),
        ),
      ),
      throwsToolExit(
        message:
            'Building native assets failed. See the logs for more details.',
      ),
    );
  });

  // This logic is mocked in the other tests to avoid having test order
  // randomization causing issues with what processes are invoked.
  // Exercise the parsing of the process output in this separate test.
  testUsingContext('NativeAssetsBuildRunnerImpl.cCompilerConfig', overrides: <Type, Generator>{
    FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true),
    ProcessManager: () => FakeProcessManager.list(
          <FakeCommand>[
            const FakeCommand(
              command: <Pattern>['which', 'clang++'],
              stdout: '''
/some/path/to/clang++
''', // Newline at the end of the string.
            )
          ],
        ),
    FileSystem: () => fileSystem,
  }, () async {
    if (!const LocalPlatform().isLinux) {
      return;
    }

    await fileSystem.directory('/some/path/to/').create(recursive: true);
    await fileSystem.file('/some/path/to/clang++').create();
    await fileSystem.file('/some/path/to/clang').create();
    await fileSystem.file('/some/path/to/llvm-ar').create();
    await fileSystem.file('/some/path/to/ld.lld').create();

    final File packageConfigFile = fileSystem
        .directory(projectUri)
        .childDirectory('.dart_tool')
        .childFile('package_config.json');
    await packageConfigFile.parent.create();
    await packageConfigFile.create();
    final PackageConfig packageConfig = await loadPackageConfigWithLogging(
      packageConfigFile,
      logger: environment.logger,
    );
    final NativeAssetsBuildRunner runner =
        NativeAssetsBuildRunnerImpl(projectUri, packageConfigFile.path, packageConfig, fileSystem, logger);
    final CCompilerConfigImpl result = await runner.cCompilerConfig;
    expect(result.compiler, Uri.file('/some/path/to/clang'));
  });
}

class _BuildRunnerWithoutClang extends FakeNativeAssetsBuildRunner {
  @override
  Future<CCompilerConfigImpl> get cCompilerConfig async =>
      throwToolExit('Failed to find clang++ on the PATH.');
}
