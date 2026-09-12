/** Pinned Milestone 1 runtime bounds. Keep in sync with ScreenpunkCore.PackageLimits. */

export const SCHEMA_MAJOR = 1;
export const SDK_VERSION = "1";
export const COMPRESSED_BYTES = 25 * 1024 * 1024;
export const EXPANDED_BYTES = 50 * 1024 * 1024;
export const MAX_FILES = 2000;
export const STATE_CACHE_BYTES = 5 * 1024 * 1024;
export const LOG_BYTES = 5 * 1024 * 1024;
export const HTTP_TIMEOUT_SECONDS = 15;
export const HTTP_RESPONSE_BYTES = 2 * 1024 * 1024;
export const WEBSOCKET_MESSAGE_BYTES = 256 * 1024;
export const MIN_POLL_SECONDS = 15;
export const WEATHER_POLL_SECONDS = 15 * 60;
export const BACKOFF_CAP_SECONDS = 60;
export const READY_TIMEOUT_SECONDS = 15;
export const MAX_STATE_KEY_BYTES = 256;
export const MAX_BRIDGE_MESSAGE_BYTES = 64 * 1024;
export const UNLINK_HOLD_SECONDS = 10;
export const OFFLINE_RING_POINTS = 4;
export const OFFLINE_LABEL_POINTS = 14;
export const OFFLINE_TAB_PAD_POINTS = 12;
