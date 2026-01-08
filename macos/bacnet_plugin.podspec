#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint bacnet_plugin.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'bacnet_plugin'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*',
                   '../../native/bacnet-stack/src/bacnet/*.c',
                   '../../native/bacnet-stack/src/bacnet/basic/**/*.c',
                   '../../native/bacnet-stack/src/bacnet/datalink/bvlc.c',
                   '../../native/bacnet-stack/src/bacnet/datalink/cobs.c',
                   '../../native/bacnet-stack/src/bacnet/datalink/datalink.c',
                   '../../native/bacnet-stack/src/bacnet/basic/bbmd/h_bbmd.c',
                   '../../native/bacnet-stack/ports/bsd/*.c'

  s.exclude_files = '../../native/bacnet-stack/src/bacnet/basic/ucix/*.c',
                    '../../native/bacnet-stack/src/bacnet/basic/bbmd6/*.c'

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.11'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) BACDL_BIP BACNET_STACK_STATIC_DEFINE PRINT_ENABLED=0',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../../native/bacnet-stack/src" "$(PODS_TARGET_SRCROOT)/../../native/bacnet-stack/ports/bsd"'
  }
  s.swift_version = '5.0'
end
