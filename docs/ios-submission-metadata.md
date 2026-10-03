# iOS submission metadata

The app manifest declares app-owned defaults (CA92.1), elapsed event timing (35F9.1), and app-container file metadata (C617.1). It makes no data-collection or tracking declaration. Review the final archive privacy report and provider/backend behavior before submission.

Developer builds use 1.0(1). Signed release export requires explicit IOS_MARKETING_VERSION and IOS_BUILD_NUMBER through workflow inputs. Marketing versions use two or three numeric components; build numbers use the project policy of a positive integer up to four digits. The September 30 receipt proves an existing 1.0(1); it does not establish the current highest ASC build. Check App Store Connect and choose an unused higher build before dispatch. This validator does not contact ASC or reserve numbers.

Input validation runs before sourcing signing helpers/importing certificates. Export validation checks bundle ID, supplied version/build, minimum iOS16 and both device families before copying the final IPA. Encryption declarations are unchanged.

Run python3 scripts/ci/test-ios-release-metadata.py and bash -n .github/workflows/scripts/ios-archive-export.sh. Then confirm privacy manifest inclusion in the generated project and final archive during production qualification.

Apple primary mapping: [API categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) and [approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons). CA92.1 covers app-only defaults in GoogleTVConnection/GoogleTVADBConnection, DeviceGoogleTVSettings and the iOS AppleMapPreview branch. 35F9.1 covers elapsed voice-tap and packet/session timing in HomeAssistantWebBridge and GoogleTVSession; raw uptime is not transmitted. C617.1 covers app-container modes, inode identity and size inspected by fstat/lstat in reset stores, filesystem cleanup and ScreenPreferenceAtomicWriter. Apple lists these functions even when timestamp fields are not used. File-size inspection does not justify a DiskSpace entry.
