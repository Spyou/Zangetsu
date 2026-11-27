package com.spyou.watch_app;

import android.Manifest;
import android.app.*;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.*;
import java.util.Arrays;

/**
 * Foreground service that lets the phone act as a Bluetooth keyboard/consumer-control remote
 * for a paired TV, using Android's public {@link BluetoothHidDevice} API (Android 9+).
 * It owns the HID profile registration, reconnects to the saved TV, and shows a media-style
 * notification whose buttons are routed through {@link RemoteCompanionBridge}.
 * All state is touched on the main looper; Kotlin callers reach it through {@link #instance}.
 */
public class RemoteConnectionService extends Service {
    /** The live service, or null when it is not running; set in onCreate, cleared in onDestroy. */
    public static RemoteConnectionService instance;
    /** True between onCreate and onDestroy, so callers can avoid starting a second copy. */
    public static boolean running;
    /** The saved TV currently connected over HID, or null. */
    public BluetoothDevice target;
    /** Whether our HID app is registered with the Bluetooth stack (see onAppStatusChanged). */
    public boolean registered;
    /** Human-readable status line shown in the notification and the Manage screen. */
    public String detail = "Remote starting";
    /** Optional callback run on every status change, used by the UI to refresh itself. */
    public Runnable observer;
    /** Connection lifecycle: get the profile proxy, register the HID app, then connect the TV. */
    private enum Phase { IDLE, PROFILE, REGISTERING, READY, CONNECTING, CONNECTED, CLOSED }
    private Phase phase = Phase.IDLE;
    private final Handler queue = new Handler(Looper.getMainLooper());
    private BluetoothAdapter adapter;
    private BluetoothHidDevice profile;
    private SharedPreferences preferences;
    private RemoteMediaSession media;
    /** Last known TV player visibility/play state, and whether startForeground has run. */
    private boolean playerVisible, playing, foreground;
    /** Report id (1 keyboard, 2 consumer) and payload of the key currently held; 0 if none. */
    private int activeReport;
    private byte[] activePayload;
    /** Delayed release queued by {@link #tap}; cancelled when another key is pressed. */
    private Runnable pendingRelease;
    /** Foreground notification id and its low-importance channel id. */
    private static final int NOTIFICATION = 41285;
    private static final String CHANNEL = "remote_connection";

    // HID short items: keyboard report 1 (modifier/reserved/six keys),
    // consumer report 2 (one unsigned 16-bit usage). Values are protocol fields.
    /**
     * Builds the HID report descriptor: report 1 is an 8-byte boot-style keyboard report and
     * report 2 is a 2-byte little-endian consumer-control usage (volume, media keys).
     */
    private static byte[] descriptor() {
        int[] items = {
            0x05,1, 0x09,6, 0xA1,1, 0x85,1,
            0x05,7, 0x15,0, 0x25,1, 0x19,0xE0, 0x29,0xE7,
            0x75,1, 0x95,8, 0x81,2,
            0x75,8, 0x95,1, 0x81,1,
            0x15,0, 0x26,0xFF,0, 0x19,0, 0x2A,0xFF,0,
            0x75,8, 0x95,6, 0x81,0, 0xC0,
            0x05,0x0C, 0x09,1, 0xA1,1, 0x85,2,
            0x15,0, 0x26,0xFF,3, 0x19,0, 0x2A,0xFF,3,
            0x75,16, 0x95,1, 0x81,0, 0xC0
        };
        byte[] bytes = new byte[items.length];
        for (int i = 0; i < items.length; i++) bytes[i] = (byte) items[i];
        return bytes;
    }

    /** True when BLUETOOTH_CONNECT is granted (or not needed below Android 12). */
    private boolean permitted() {
        return Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
    }
    /** True only when the HID app is registered and the saved TV is connected. */
    public boolean isConnected() { return phase == Phase.CONNECTED && registered && target != null; }
    /** Display name of the saved TV, defaulting to "TV". */
    public String savedName() { return preferences.getString("hidName", "TV"); }
    /** Bluetooth name of {@code device}, or "TV" when unknown or permission is missing. */
    public String name(BluetoothDevice device) {
        String label = permitted() ? device.getName() : null;
        return label == null || label.isEmpty() ? "TV" : label;
    }
    /** Updates {@link #detail}, refreshes the notification and runs {@link #observer}. */
    private void status(String text) {
        detail = text;
        if (foreground) getSystemService(NotificationManager.class).notify(NOTIFICATION, notification());
        if (observer != null) observer.run();
    }
    /**
     * Publishes the TV player state (the companion state JSON from the receiver) to Android
     * media surfaces without starting local audio. Called by RemoteControls on each update.
     */
    public void playbackSnapshot(org.json.JSONObject state) { if (media != null) media.update(state); }
    /**
     * Refreshes notification actions only when playback availability or play state changes.
     * @param available whether the TV player is in the foreground
     * @param isPlaying whether it is currently playing
     */
    public void playbackChanged(boolean available, boolean isPlaying) {
        if (playerVisible == available && playing == isPlaying) return;
        playerVisible = available;
        playing = isPlaying;
        if (foreground) getSystemService(NotificationManager.class).notify(NOTIFICATION, notification());
    }
    /** Notification button that re-delivers {@code command} to this service via onStartCommand. */
    private Notification.Action action(String command, String title, int icon, int id) {
        Intent intent = new Intent(this, RemoteConnectionService.class).setAction(command);
        return new Notification.Action.Builder(icon, title, PendingIntent.getService(this, id, intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE)).build();
    }
    /** Builds contextual notification controls from live HID/companion availability. */
    private Notification notification() {
        Notification.Builder result = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        result.setSmallIcon(android.R.drawable.ic_media_play).setContentTitle(isConnected() ? name(target) : "Zangetsu")
            .setContentText(detail).setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
            .setContentIntent(PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        RemoteCompanionBridge bridge = RemoteCompanionBridge.Companion.getShared();
        if (isConnected() || (bridge != null && bridge.isCompanionConnected())) {
            result.addAction(action("VOLUME_DOWN", "Volume down", R.drawable.remote_volume_down, 23));
            if (playerVisible) {
                result.addAction(action("REWIND", "Back 10 seconds", android.R.drawable.ic_media_rew, 20));
                result.addAction(action("PLAY_PAUSE", playing ? "Pause" : "Play", playing ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play, 21));
                result.addAction(action("FORWARD", "Forward 10 seconds", android.R.drawable.ic_media_ff, 22));
            }
            result.addAction(action("VOLUME_UP", "Volume up", R.drawable.remote_volume_up, 24));
            result.setStyle(new Notification.MediaStyle().setMediaSession(media.token())
                .setShowActionsInCompactView(playerVisible ? new int[]{0,2,4} : new int[]{0,1}));
        }
        return result.build();
    }
    /** Sets up preferences, the media session, the notification channel and a radio receiver. */
    @Override public void onCreate() {
        super.onCreate();
        instance = this; running = true;
        preferences = getSharedPreferences("companion_pairing", MODE_PRIVATE);
        media = new RemoteMediaSession(this);
        BluetoothManager manager = getSystemService(BluetoothManager.class);
        adapter = manager == null ? null : manager.getAdapter();
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel(CHANNEL, "TV remote", NotificationManager.IMPORTANCE_LOW));
        IntentFilter filter = new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(radio, filter, RECEIVER_EXPORTED); else registerReceiver(radio, filter);
    }
    /** Not a bound service; callers use {@link #instance}. */
    @Override public IBinder onBind(Intent intent) { return null; }
    /**
     * Handles start intents. "STOP" disconnects companions and stops the remote; the transport
     * actions (REWIND, PLAY_PAUSE, FORWARD, VOLUME_DOWN, VOLUME_UP) come from notification buttons
     * and are forwarded to the companion bridge. Any other start promotes to foreground and
     * reconciles the HID connection.
     */
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String command = intent == null ? "" : intent.getAction();
        if ("STOP".equals(command)) {
            RemoteCompanionBridge bridge = RemoteCompanionBridge.Companion.getShared();
            if (bridge != null) bridge.disconnectAll();
            stopRemote(); return START_NOT_STICKY;
        }
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        else startForeground(NOTIFICATION, notification());
        foreground = true;
        if (Arrays.asList("REWIND", "PLAY_PAUSE", "FORWARD", "VOLUME_DOWN", "VOLUME_UP").contains(command)) {
            RemoteCompanionBridge bridge = RemoteCompanionBridge.Companion.getShared();
            if (bridge != null) bridge.notificationControl(command);
            else status("Open Zangetsu to reconnect");
        }
        ensure();
        return START_NOT_STICKY;
    }
    /** Retry task that re-runs {@link #ensure}. */
    private final Runnable reconcile = () -> ensure();
    /** Keeps one pending retry of {@link #ensure} after {@code delay} ms, unless closed. */
    private void schedule(long delay) { queue.removeCallbacks(reconcile); if (phase != Phase.CLOSED) queue.postDelayed(reconcile, delay); }
    /**
     * Reconciles permission, radio, profile registration and saved-device connection state,
     * advancing one step per call; callbacks and retries call it again. Safe to call repeatedly.
     */
    public void ensure() {
        if (phase == Phase.CLOSED) return;
        if (Build.VERSION.SDK_INT < 28) { status("Bluetooth remote requires Android 9 or newer"); return; }
        if (!preferences.getBoolean("hidEnabled", false)) { status("Use Manage to enable Bluetooth controls"); return; }
        if (!permitted()) { status("Allow Nearby devices to use Bluetooth controls"); return; }
        if (adapter == null || !adapter.isEnabled()) { status("Bluetooth is off"); return; }
        try {
            if (profile == null) {
                if (phase == Phase.PROFILE) return;
                phase = Phase.PROFILE;
                if (!adapter.getProfileProxy(this, profileEvents, BluetoothProfile.HID_DEVICE)) { phase = Phase.IDLE; status("Bluetooth remote profile unavailable"); schedule(5000); }
                return;
            }
            if (!registered) {
                if (phase == Phase.REGISTERING) return;
                phase = Phase.REGISTERING;
                boolean accepted = profile.registerApp(new BluetoothHidDeviceAppSdpSettings("Zangetsu", "TV controls", "Zangetsu", BluetoothHidDevice.SUBCLASS1_KEYBOARD, descriptor()), null, null, queue::post, events);
                if (!accepted) { phase = Phase.IDLE; status("Close another Bluetooth remote app, then retry"); schedule(5000); }
                return;
            }
            if (isConnected() || phase == Phase.CONNECTING) return;
            String wanted = preferences.getString("hidAddress", "");
            for (BluetoothDevice device : adapter.getBondedDevices()) if (device.getAddress().equals(wanted)) { connect(device); return; }
            status(wanted.isEmpty() ? "Choose a paired TV in Manage" : "Pair the saved TV in Bluetooth settings");
        } catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
    }
    /** Receives the HID_DEVICE profile proxy and resets state if the Bluetooth service dies. */
    private final BluetoothProfile.ServiceListener profileEvents = new BluetoothProfile.ServiceListener() {
        @Override public void onServiceConnected(int id, BluetoothProfile service) {
            if (phase == Phase.CLOSED) { if (adapter != null) adapter.closeProfileProxy(id, service); return; }
            profile = (BluetoothHidDevice) service; phase = Phase.IDLE; ensure();
        }
        @Override public void onServiceDisconnected(int id) {
            profile = null; registered = false; target = null; activeReport = 0;
            if (phase != Phase.CLOSED) { phase = Phase.IDLE; status("Bluetooth service reconnecting"); schedule(5000); }
        }
    };
    /**
     * HID callbacks, delivered on the main looper: registration status, host connections (only
     * the saved TV is accepted; with no saved TV and the remote enabled, the first host that connects is adopted), report
     * polls from the TV, and virtual cable unplug, which forgets the saved TV.
     */
    private final BluetoothHidDevice.Callback events = new BluetoothHidDevice.Callback() {
        @Override public void onAppStatusChanged(BluetoothDevice host, boolean ready) {
            if (phase == Phase.CLOSED) return;
            registered = ready; phase = ready ? Phase.READY : Phase.IDLE;
            if (!ready) { target = null; activeReport = 0; status("Bluetooth registration unavailable; close other remote apps"); schedule(5000); }
            else ensure();
        }
        @Override public void onConnectionStateChanged(BluetoothDevice host, int state) {
            if (phase == Phase.CLOSED || !permitted()) return;
            try {
                String saved = preferences.getString("hidAddress", "");
                if (saved.isEmpty() && preferences.getBoolean("hidEnabled", false)) {
                    // Fallback path: the TV found this phone itself, so adopt the first host that connects.
                    if (state != BluetoothProfile.STATE_CONNECTED) return;
                    preferences.edit().putString("hidAddress", host.getAddress()).putString("hidName", name(host)).apply();
                } else if (!host.getAddress().equals(saved)) { if (profile != null) profile.disconnect(host); return; }
                if (state == BluetoothProfile.STATE_CONNECTED) {
                    queue.removeCallbacks(connectionTimeout); target = host; phase = Phase.CONNECTED;
                    preferences.edit().putString("hidName", name(host)).apply(); status("Connected to " + name(host));
                } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                    queue.removeCallbacks(connectionTimeout); target = null; activeReport = 0; phase = Phase.READY;
                    status("TV disconnected; reconnecting"); schedule(5000);
                }
            } catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
        }
        @Override public void onGetReport(BluetoothDevice host, byte type, byte id, int bufferSize) {
            if (!isConnected() || !host.equals(target) || !permitted() || profile == null) return;
            try {
                if (type != BluetoothHidDevice.REPORT_TYPE_INPUT || (id != 1 && id != 2)) { profile.reportError(host, BluetoothHidDevice.ERROR_RSP_UNSUPPORTED_REQ); return; }
                byte[] payload = activeReport == id && activePayload != null ? activePayload.clone() : new byte[id == 1 ? 8 : 2];
                if (bufferSize > 0 && bufferSize < payload.length) { profile.reportError(host, BluetoothHidDevice.ERROR_RSP_INVALID_PARAM); return; }
                profile.replyReport(host, type, id, payload);
            } catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
        }
        @Override public void onVirtualCableUnplug(BluetoothDevice host) {
            if (target != null && !target.equals(host)) return;
            target = null; activeReport = 0;
            preferences.edit().remove("hidAddress").remove("hidName").putBoolean("hidEnabled", false).apply();
            queue.removeCallbacks(connectionTimeout); queue.removeCallbacks(reconcile);
            if (phase != Phase.CLOSED) { phase = Phase.READY; status("TV removed pairing; choose the TV again"); }
        }
    };
    /** Gives up a connect attempt that has not completed within 20 seconds and retries later. */
    private final Runnable connectionTimeout = () -> {
        if (phase != Phase.CONNECTING) return;
        phase = Phase.READY; status("TV did not connect; retrying"); schedule(5000);
    };
    /** Connects only the saved bonded target; unsolicited peers are rejected in callbacks. */
    public void connect(BluetoothDevice device) {
        if (!registered || profile == null || !permitted() || phase == Phase.CLOSED) return;
        if (isConnected() || phase == Phase.CONNECTING) return;
        if (!device.getAddress().equals(preferences.getString("hidAddress", ""))) return;
        try {
            if (profile.connect(device)) {
                phase = Phase.CONNECTING; status("Connecting to " + name(device));
                queue.removeCallbacks(connectionTimeout); queue.postDelayed(connectionTimeout, 20000);
            } else { status("TV unavailable; retrying"); schedule(5000); }
        } catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
    }
    /**
     * Sends one validated HID key-down report after releasing any previous report.
     * @param report 1 for a keyboard usage (0-255), 2 for a consumer usage (0-1023)
     * @param usage HID usage code; out-of-range values are ignored
     */
    public void press(int report, int usage) {
        if ((report != 1 && report != 2) || usage < 0 || usage > (report == 1 ? 255 : 1023)) return;
        release();
        if (!isConnected() || !permitted()) return;
        byte[] payload = new byte[report == 1 ? 8 : 2];
        if (report == 1) payload[2] = (byte) usage;
        else { payload[0] = (byte) usage; payload[1] = (byte) (usage >>> 8); }
        try {
            if (profile.sendReport(target, report, payload)) { activeReport = report; activePayload = payload; }
            else status("TV did not accept the button");
        } catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
    }
    /** Cancels pending release work and sends an empty report to prevent stuck TV keys. */
    public void release() {
        if (pendingRelease != null) queue.removeCallbacks(pendingRelease);
        pendingRelease = null;
        int report = activeReport; activeReport = 0; activePayload = null;
        if (report == 0 || !isConnected() || !permitted()) return;
        try { profile.sendReport(target, report, new byte[report == 1 ? 8 : 2]); }
        catch (SecurityException denied) { status("Bluetooth permission is unavailable"); }
    }
    /** Presses, then releases natively after 25 ms so a lost Flutter pointer-up cannot hold a key. */
    public void tap(int report, int usage) { press(report, usage); pendingRelease = this::release; queue.postDelayed(pendingRelease, 25); }
    /** Taps a consumer-control volume usage, used for the phone's hardware volume keys. */
    public void hardwareVolume(int usage) { tap(2, usage); }
    /** Drops HID state when Bluetooth turns off and reconciles again when it turns back on. */
    private final BroadcastReceiver radio = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (phase == Phase.CLOSED) return;
            int state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1);
            if (state == BluetoothAdapter.STATE_OFF) { target = null; registered = false; activeReport = 0; phase = Phase.IDLE; status("Bluetooth is off"); }
            else if (state == BluetoothAdapter.STATE_ON) ensure();
        }
    };
    /** Cancels retry/input work before unregistering and releasing the Android HID profile. */
    private void closeProfile() {
        release(); phase = Phase.CLOSED; queue.removeCallbacksAndMessages(null);
        if (profile != null && permitted()) {
            try { if (target != null) profile.disconnect(target); profile.unregisterApp(); }
            catch (SecurityException ignored) { }
        }
        if (adapter != null && profile != null) adapter.closeProfileProxy(BluetoothProfile.HID_DEVICE, profile);
        profile = null; target = null; registered = false;
    }
    /** Disables saved HID auto-connect and stops the foreground service. */
    public void stopRemote() {
        preferences.edit().putBoolean("hidEnabled", false).apply(); closeProfile();
        foreground = false; stopForeground(STOP_FOREGROUND_REMOVE); stopSelf();
    }
    /** Closes the HID profile, receiver and media session and clears the static handles. */
    @Override public void onDestroy() {
        foreground = false; closeProfile(); unregisterReceiver(radio); media.close(); observer = null;
        if (instance == this) instance = null;
        running = false; super.onDestroy();
    }
}
