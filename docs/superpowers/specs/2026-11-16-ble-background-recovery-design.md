# Bluetooth recording recovery

Restore RR recording without opening the app after a stalled HR subscription or standby. Keep intentional user disconnect authoritative and preserve existing off-body and gap policies.

The existing watchdog only notices a disconnected peripheral, and standby cancels it. A connected H10 can therefore keep sending PMD or HR-without-RR indefinitely without recovery.

Use an event-driven RR recovery state machine in BLEService, also checked by the existing watchdog and app lifecycle transitions. After 15 seconds without useful RR on a responsive connection, refresh the HR subscription; after another 10 seconds without recovery, cancel the connection and let the existing disconnect callback arm a persistent CoreBluetooth connection. A fully silent connection gets an RSSI probe after 30 seconds and reconnect after a further 10 seconds. Keep a 60-second reconnect cooldown across automatic reconnects. Fresh off-body HR beacons suppress unnecessary retries; a stale contact flag alone does not.

Timer-only recovery cannot run during iOS suspension. Bluetooth callbacks are the main background trigger; the timer supplements them while execution is available. Retain bluetooth-central and state restoration. A fully suspended app with no Bluetooth event cannot guarantee a deadline; force-quit is outside the restoration contract.

Alternatives considered: reconnect immediately on any missing RR (too disruptive for transient gaps/off-body); timer-only watchdog (does not address background suspension). These are implementation choices within the requested bug fix.

The first accepted HR refresh clears buffered signals through connectionGapSubject before issuing the subscription/discovery command. A successful refresh must not silently join RR intervals across the outage. Its acknowledgement only enables notifications and does not clear again.

Verify deterministic event sequences without foreground/timer ticks, existing standby/gap behavior, cooldown, stale timestamps, connection lifecycle resets, and command sequencing. Simulator tests cannot establish real H10 radio behavior, delegate delivery or iOS wake delivery; those need a locked physical iPhone and H10.

Platform references: [Apple background processing guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html), [Bluetooth state restoration rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules).
