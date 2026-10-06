/// @docImport '../client/bacnet_client.dart';
library;

import 'package:meta/meta.dart';

import 'bacnet_value.dart';

/// A value for the Channel objects with channel number [channel] of a
/// WriteGroup ([BacnetClient.writeGroup], BACnetGroupChannelValue).
@immutable
final class BacnetGroupChannelValue {
  /// Creates the value; [overridingPriority] (1..16) replaces the write
  /// priority of the request for this channel.
  BacnetGroupChannelValue(this.channel, this.value, {this.overridingPriority}) {
    RangeError.checkValueInInterval(channel, 0, 0xFFFF, 'channel');
    if (overridingPriority case final priority?) {
      RangeError.checkValueInInterval(priority, 1, 16, 'overridingPriority');
    }
  }

  /// The channel number (Channel_Number of the Channel objects).
  final int channel;

  /// The value: a primitive value such as [BacnetReal], [BacnetUnsigned],
  /// [BacnetBoolean] or [BacnetNull] (relinquish).
  final BacnetValue value;

  /// Priority for this channel, null for the priority of the request.
  final int? overridingPriority;

  @override
  bool operator ==(Object other) =>
      other is BacnetGroupChannelValue &&
      other.channel == channel &&
      other.value == value &&
      other.overridingPriority == overridingPriority;

  @override
  int get hashCode => Object.hash(channel, value, overridingPriority);

  @override
  String toString() =>
      'BacnetGroupChannelValue(channel $channel = $value'
      '${overridingPriority == null ? '' : ' @ $overridingPriority'})';
}
