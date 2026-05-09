package com.elodin.walkie_talkie

import android.service.notification.NotificationListenerService

/**
 * Minimal NotificationListenerService that grants this app permission to call
 * MediaSessionManager.getActiveSessions(). The service itself does nothing —
 * all MediaSession work is in MediaSessionBridge.
 *
 * Enabled by the user in Settings → Apps → Special app access → Notification access.
 */
class WalkieTalkieNotificationListener : NotificationListenerService()
