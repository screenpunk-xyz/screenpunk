import assert from "node:assert/strict";
import { test } from "node:test";
import {
  APPROVED_PORCELAIN,
  APPROVED_SOOT,
  BUNDLE_ID_PREFIX,
  COPYRIGHT_OWNER,
  DANGER_DARK,
  DANGER_LIGHT,
  DEFAULT_LOCKUP,
  IOS_BUNDLE_ID,
  IOS_27_REQUIRED_TO_RUN,
  IOS_MINIMUM,
  LOGOMARK_REVISION,
  MAC_BUNDLE_ID,
  MACOS_MINIMUM,
  PREVIEW_HOST_BUNDLE_ID,
  OFFLINE_USES_SYSTEM_RED,
  SCHEMA_MAJOR,
  STYLE_GUIDE_URL,
  WORDMARK_REVISION
} from "../src/identity.ts";

test("locked identity and stacked lockup", () => {
  assert.equal(APPROVED_SOOT, "#15191C");
  assert.equal(APPROVED_PORCELAIN, "#F4EFE5");
  assert.equal(LOGOMARK_REVISION, "8-bevel");
  assert.equal(WORDMARK_REVISION, "v1-modular");
  assert.equal(DEFAULT_LOCKUP, "stacked");
  assert.equal(STYLE_GUIDE_URL, "https://screenpunk-style-guide.gsuter.chatgpt.site");
});

test("danger offline and platform fallbacks", () => {
  assert.equal(IOS_MINIMUM, "16.0");
  assert.equal(MACOS_MINIMUM, "26.0");
  assert.equal(IOS_27_REQUIRED_TO_RUN, false);
  assert.equal(SCHEMA_MAJOR, 1);
  assert.equal(OFFLINE_USES_SYSTEM_RED, false);
  assert.equal(DANGER_LIGHT, "#A52C42");
  assert.equal(DANGER_DARK, "#FF8BA0");
  assert.equal(COPYRIGHT_OWNER, "Screenpunk, Inc.");
  assert.equal(BUNDLE_ID_PREFIX, "xyz.screenpunk");
  assert.equal(IOS_BUNDLE_ID, "xyz.screenpunk.ios");
  assert.equal(MAC_BUNDLE_ID, "xyz.screenpunk.macos");
  assert.equal(PREVIEW_HOST_BUNDLE_ID, "xyz.screenpunk.preview-host");
});
