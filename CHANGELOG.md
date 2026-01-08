# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1] - 2026-01-07

### Added

#### Core Features

- **BACnet Client** - Full client implementation with support for:
  - Device discovery (Who-Is/I-Am)
  - Read Property / Read Property Multiple
  - Write Property / Write Property Multiple
  - Change of Value (COV) subscriptions
  - Foreign Device Registration
  - Device scanning and object enumeration
- **BACnet Server** - Server implementation for hosting objects:
  - Device initialization
  - Object hosting (Analog, Binary, Multi-state)
  - Write notification events
  - Read/Write property handling

#### Developer Experience

- **Named Constants** - Complete set of BACnet protocol constants:

  - `BacnetObjectType` - 25+ object types with human-readable names
  - `BacnetPropertyId` - 80+ property identifiers
  - `BacnetErrorClass` and `BacnetErrorCode` - Comprehensive error constants

- **Modern Logging**:

  - `DeveloperBacnetLogger` - Dart DevTools integration
  - `ConsoleBacnetLogger` - Simple console output
  - Pluggable logger interface for custom implementations

- **Type Safety**:

  - Strict type checking throughout
  - Named constants replace magic numbers
  - Comprehensive parameter documentation

- **JSON Serialization**:
  - All models support `toJson()`/`fromJson()`
  - Generated with `json_serializable`
  - Easy API integration

#### Data Models

- **Immutable Models**:

  - `BacnetObject` - Object representation with properties
  - `BacnetPropertyReference` - Property references for RPM
  - `BacnetReadAccessSpecification` - RPM request specification
  - `BacnetWriteAccessSpecification` - WPM request specification
  - `BacnetPropertyValue` - Property values for WPM

- **Model Features**:
  - `@immutable` annotations
  - `copyWith()` methods for updates
  - Equality operators (`==`, `hashCode`)
  - Helper getters (name, presentValue, etc.)
  - Full dartdoc documentation

#### Configuration

- **BacnetConfig** - Centralized configuration:
  - Interface binding
  - Port configuration
  - Timeout settings
  - Retry configuration
  - Logger selection

#### Error Handling

- **Exception Hierarchy**:
  - `BacnetException` - Base exception
  - `BacnetTimeoutException` - Request timeouts
  - `BacnetNotInitializedException` - Uninitialized operations
  - `BacnetProtocolException` - Protocol errors with error codes

#### Documentation

- **Complete API Documentation**:

  - Every public API has dartdoc comments
  - Usage examples for all major features
  - Parameter explanations with constant references
  - Return value documentation

- **Project Documentation**:
  - Comprehensive README.md with examples
  - CONTRIBUTING.md guide
  - Architecture diagrams
  - Quick start guides

#### Code Quality

- **Linting**:

  - 100+ lint rules configured
  - Strict type checking enabled
  - Code style enforcement (single quotes, const, etc.)
  - Documentation requirements

- **Code Generation**:
  - `build_runner` integration
  - JSON serialization generation
  - FFI bindings generation

### Architecture

- **Isolate-Based Design**:
  - Non-blocking network operations
  - Smooth UI performance
  - Background processing
  - Worker isolate for native BACnet stack

### Platforms

- ✅ Windows
- ✅ Linux
- ✅ macOS
- ✅ Android
- ✅ iOS

### Dependencies

- `ffi: ^2.1.4` - Foreign Function Interface
- `json_annotation: ^4.9.0` - JSON annotations
- `meta: ^1.15.0` - Metadata annotations
- `plugin_platform_interface: ^2.1.8` - Platform interface

### Dev Dependencies

- `build_runner: ^2.4.0` - Code generation
- `json_serializable: ^6.8.0` - JSON serialization
- `mocktail: ^1.0.0` - Mocking for tests
- `flutter_lints: ^6.0.0` - Linting rules

### Known Limitations

- Trend log reading returns dummy data (planned for future release)
- Device scanning limited to first 10 objects
- Some native worker code lacks public documentation
- WritePropertyMultiple native binding pending implementation

## [Unreleased]

### Planned Features

- Complete trend log implementation
- Device scanner utility class
- Property monitor with automatic polling
- Enhanced example app with UI
- Unit test suite (>80% coverage)
- API reference documentation
- More integration tests

---

[0.0.1]: https://github.com/gencto/bacnet_plugin/releases/tag/v0.0.1
[Unreleased]: https://github.com/gencto/bacnet_plugin/compare/v0.0.1...HEAD
