# Contributing to BACnet Plugin

Thank you for your interest in contributing to the BACnet Flutter plugin! This document provides guidelines and instructions for contributing.

## Code of Conduct

By participating in this project, you agree to maintain a respectful and inclusive environment for all contributors.

## How to Contribute

### Reporting Issues

Before creating an issue, please:

1. Check if the issue already exists in [GitHub Issues](https://github.com/gencto/bacnet_plugin/issues)
2. Collect relevant information (Flutter version, platform, error messages)
3. Create a minimal reproduction case if possible

**Issue Template:**

```markdown
**Description:**
Brief description of the issue

**Steps to Reproduce:**

1. Step one
2. Step two
3. ...

**Expected Behavior:**
What you expected to happen

**Actual Behavior:**
What actually happened

**Environment:**

- Flutter version: X.X.X
- Dart version: X.X.X
- Platform: Windows/Linux/macOS/Android/iOS
- Plugin version: X.X.X

**Additional Context:**
Error messages, screenshots, code snippets
```

### Suggesting Features

Feature suggestions are welcome! Please:

1. Check existing issues and discussions
2. Clearly describe the use case
3. Explain how it aligns with BACnet protocol standards
4. Provide examples if possible

### Pull Requests

We love pull requests! Here's the process:

1. **Fork and Clone**

   ```bash
   git clone --recurse-submodules https://github.com/YOUR_USERNAME/bacnet_plugin.git
   cd bacnet_plugin
   # existing clone: git submodule update --init
   ```

   `native/bacnet-stack` is a git submodule pinned to a bacnet-stack
   release. The native library is compiled by `hook/build.dart` the first
   time a test, app or benchmark runs; a C compiler is required (clang/gcc
   on Linux, Xcode on macOS/iOS, Visual Studio with the C++ workload on
   Windows, the Android NDK installed by Flutter for Android).

2. **Create a Branch**

   ```bash
   git checkout -b feature/my-feature
   # or
   git checkout -b fix/my-bugfix
   ```

3. **Make Changes**

   - Follow the code style guidelines (see below)
   - Add tests for new functionality
   - Update documentation as needed
   - Run code generation if modifying models

4. **Test Your Changes**

   ```bash
   # Static analysis and formatting
   dart analyze --fatal-infos lib test hook benchmark tool
   dart format lib test hook benchmark tool

   # Unit tests
   dart test --exclude-tags integration

   # Client/server integration tests over the loopback interface
   dart test --tags integration

   # Example app
   cd example
   flutter analyze
   flutter test integration_test/app_test.dart -d flutter-tester
   ```

5. **Generate Code** (if you modified models with @JsonSerializable)

   ```bash
   dart run build_runner build --delete-conflicting-outputs
   ```

6. **Commit Changes**

   ```bash
   git add .
   git commit -m "feat: add new feature"
   # or
   git commit -m "fix: resolve issue #123"
   ```

   Use conventional commit messages:

   - `feat:` New features
   - `fix:` Bug fixes
   - `docs:` Documentation changes
   - `style:` Code style changes (formatting)
   - `refactor:` Code refactoring
   - `test:` Adding or updating tests
   - `chore:` Maintenance tasks

7. **Push and Create PR**

   ```bash
   git push origin feature/my-feature
   ```

   Then create a Pull Request on GitHub.

## Code Style Guidelines

This project follows the Flutter/Dart style guide from [.agent/rules/rules.md](file:///c:/Projects/Flutter/bacnet_plugin/.agent/rules/rules.md).

### Key Points

**General:**

- Use single quotes for strings
- Prefer `const` constructors when possible
- Line length: 80 characters
- Use meaningful, descriptive names
- No abbreviations

**Classes:**

- Use `PascalCase` for class names
- Use `camelCase` for methods and variables
- Use `snake_case` for filenames
- Make classes immutable when possible
- Use `@immutable` annotation
- Implement `copyWith()` for data classes

**Documentation:**

- Add dartdoc (`///`) to all public APIs
- Include examples in documentation
- Document parameters and return values
- Explain complex logic with inline comments

**Functions:**

- Keep functions short (< 20 lines ideally)
- Single responsibility principle
- Use `async`/`await` for asynchronous operations
- Proper error handling with try-catch

**Imports:**

- Organize imports: dart, package, relative
- Use `show` or `hide` to limit imports when appropriate

**Example:**

````dart
/// Represents a BACnet device with its metadata.
///
/// Example:
/// ```dart
/// final device = BacnetDevice(
///   deviceId: 1234,
///   name: 'Building Controller',
///   ipAddress: '192.168.1.100',
/// );
/// ```
@immutable
class BacnetDevice {
  /// Creates a BACnet device.
  const BacnetDevice({
    required this.deviceId,
    required this.name,
    required this.ipAddress,
  });

  /// The unique device instance number.
  final int deviceId;

  /// The human-readable device name.
  final String name;

  /// The IP address of the device.
  final String ipAddress;

  /// Creates a copy of this device with updated values.
  BacnetDevice copyWith({
    int? deviceId,
    String? name,
    String? ipAddress,
  }) {
    return BacnetDevice(
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      ipAddress: ipAddress ?? this.ipAddress,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BacnetDevice && other.deviceId == deviceId;
  }

  @override
  int get hashCode => deviceId.hashCode;
}
````

## Testing Guidelines

### Unit Tests

Place unit tests in `test/` directory:

```dart
import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:test/test.dart';

void main() {
  group('BacnetObject', () {
    test('creates object with required fields', () {
      final obj = BacnetObject(
        type: BacnetObjectType.analogInput,
        instance: 1,
      );

      expect(obj.type, equals(BacnetObjectType.analogInput));
      expect(obj.instance, equals(1));
    });

    test('copyWith updates only specified fields', () {
      final obj = BacnetObject(type: 0, instance: 1);
      final updated = obj.copyWith(instance: 2);

      expect(updated.type, equals(0));
      expect(updated.instance, equals(2));
    });
  });
}
```

### Integration Tests

The native stack is process global, so client/server tests start the
server in a second process (`tool/demo_server.dart`) and talk to it over
the loopback interface. See `test/integration/client_server_test.dart` and
tag new tests with `@Tags(['integration'])`.

Interoperability with the reference implementation can be checked with the
bacnet-stack demo applications (`bacserv`, `bacrp`, `bacwp`, ...):

```bash
make -C native/bacnet-stack BACDL=bip server readprop   # in a copy of the stack
BACNET_IFACE=lo BACNET_IP_PORT=47830 bin/bacserv 2002 &
dart run tool/interop_client.dart 47830 2002
```

Load tests live in `benchmark/`:

```bash
dart run tool/demo_server.dart 47811 1001 200 &
dart run benchmark/load_test.dart --targets 127.0.0.1:47811:1001 \
    --requests 50000 --interface lo
dart run benchmark/server_benchmark.dart 10000 lo
```

### Test Coverage

Aim for:

- **80%+ code coverage** for public APIs
- **100% coverage** for data models
- Integration tests for key user flows

## Documentation

When adding new features:

1. **Update README.md** - Add examples and usage instructions
2. **Add dartdoc comments** - Document all public APIs
3. **Update CHANGELOG.md** - Describe changes in version
4. **Consider adding examples** - In `example/` directory

## BACnet Protocol Compliance

When implementing BACnet features:

1. **Follow ASHRAE Standard 135**
2. **Use official BACnet terminology**
3. **Reference the standard in comments**
4. **Add protocol constants** to appropriate constant files
5. **Test against real BACnet devices** when possible

Example:

```dart
/// BACnet Acknowledge-Alarm service (ASHRAE 135-2020, Section 15.2).
Future<void> acknowledgeAlarm(...) async {
  // Implementation
}
```

## Code Generation

Models use `json_serializable` for JSON support:

1. **Add annotations:**

   ```dart
   @immutable
   @JsonSerializable()
   class MyModel {
     // ...
     factory MyModel.fromJson(Map<String, dynamic> json) =>
         _$MyModelFromJson(json);
     Map<String, dynamic> toJson() => _$MyModelToJson(this);
   }
   ```

2. **Add part directive:**

   ```dart
   part 'my_model.g.dart';
   ```

3. **Run code generation:**

   ```bash
   dart run build_runner build --delete-conflicting-outputs
   ```

4. **Commit generated files** - Include `.g.dart` files in commits

## Native Code Changes

The Dart code only talks to the small engine API in
`native/src/bacnet_plugin.h`; bacnet-stack internals stay private to the
native library.

1. Change `native/src/bacnet_plugin.{h,c}` (engine) or
   `native/src/bp_port_posix.c` (BACnet/IP datalink for Linux, Android,
   macOS and iOS). Windows uses the bacnet-stack `ports/win32` sources.
2. Regenerate the FFI bindings (`@Native` functions, needs libclang):
   ```bash
   dart run ffigen --config ffigen.yaml
   ```
3. After updating the bacnet-stack submodule, regenerate the server object
   table and re-run all tests:
   ```bash
   git -C native/bacnet-stack checkout bacnet-stack-X.Y.Z
   python3 tool/gen_object_table.py
   ```
4. Compiler flags, defines and the source list are in `hook/build.dart`.
5. Keep every engine call except `bacnet_plugin_wakeup` on the worker
   isolate: the stack is not thread safe.

## Release Process

For maintainers:

1. Update version in `pubspec.yaml`
2. Update `CHANGELOG.md` with changes
3. Run all tests and checks
4. Check the package contents: `dart pub publish --dry-run`
5. Create git tag: `git tag v0.1.0`
6. Push tag: `git push origin v0.1.0` (CI publishes to pub.dev via OIDC)
7. Create GitHub release with notes

## Questions?

- Open a discussion on [GitHub Discussions](https://github.com/gencto/bacnet_plugin/discussions)
- Ask in issues if related to a specific problem
- Check existing documentation and examples first

## Thank You!

Your contributions make this project better for everyone. Thank you for taking the time to contribute!

---

**Happy Coding! 🚀**
