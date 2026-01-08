enum AppMode {
  client,
  server;

  String get displayName => switch (this) {
    AppMode.client => 'Client',
    AppMode.server => 'Server',
  };

  String get description => switch (this) {
    AppMode.client => 'Discover and control BACnet devices',
    AppMode.server => 'Create and manage BACnet objects',
  };
}
