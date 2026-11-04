const notificationModes = {
  'off': 'Off',
  'notifications': 'Notifications only',
  'sound': 'Sound only',
  'notifications-and-sound': 'Notifications with sound',
};

bool hasSystemNotifications(String mode) => mode == 'notifications' || mode == 'notifications-and-sound';
bool hasNotificationSound(String mode) => mode == 'sound' || mode == 'notifications-and-sound';
