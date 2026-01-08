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
   git clone https://github.com/YOUR_USERNAME/bacnet_plugin.git
   cd bacnet_plugin
   ```

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
   # Run static analysis
   flutter analyze

   # Format code
   dart format .

   # Run tests
   flutter test

   # Run integration tests
   cd example
   flutter test integration_test/
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

- Organize imports: dart, flutter, package, relative
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
import 'package:flutter_test/flutter_test.dart';

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

Place integration tests in `example/integration_test/`:

```dart
import 'package:bacnet_plugin/bacnet_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Client can start and stop', (tester) async {
    final client = BacnetClient();

    await client.start();
    await Future.delayed(Duration(seconds: 1));

    client.dispose();

    expect(true, isTrue); // Test passed
  });
}
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

If modifying native BACnet stack code:

1. Update header files in `native/include/`
2. Update bindings configuration in `ffigen.yaml`
3. Regenerate FFI bindings:
   ```bash
   dart run ffigen --config ffigen.yaml
   ```
4. Test on all supported platforms
5. Document any platform-specific behavior

## Release Process

For maintainers:

1. Update version in `pubspec.yaml`
2. Update `CHANGELOG.md` with changes
3. Run all tests and checks
4. Create git tag: `git tag v0.0.2`
5. Push tag: `git push origin v0.0.2`
6. Create GitHub release with notes
7. Publish to pub.dev: `flutter pub publish`

## Questions?

- Open a discussion on [GitHub Discussions](https://github.com/gencto/bacnet_plugin/discussions)
- Ask in issues if related to a specific problem
- Check existing documentation and examples first

## Thank You!

Your contributions make this project better for everyone. Thank you for taking the time to contribute!

---

**Happy Coding! 🚀**
