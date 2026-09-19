import Foundation
import OSLog
import WebKit
#if os(iOS)
import AVFAudio
#endif

/// Shared by the device host and Mac preview. Does not grant remote media access.
@MainActor
public enum BundledAudio {
    public static func configure(_ configuration: WKWebViewConfiguration) {
        // Keep browser gesture protection: play() must start in the tap handler,
        // before awaiting native work. Do not enable arbitrary autoplay.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
#if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        do {
            // Dashboard feedback remains audible in silent mode, mixes with music,
            // and still respects output volume and the selected system route.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } catch {
            AudioDiagnostics.logger.error("AUDIO_SESSION_FAILED: Could not configure dashboard audio; check the system audio route.")
        }
#endif
        configuration.userContentController.add(AudioDiagnostics(), name: "screenpunkAudioDiagnostic")
        configuration.userContentController.addUserScript(WKUserScript(
            source: diagnosticScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    static let diagnosticScript = """
    (() => {
      const messages = {
        AUDIO_GESTURE_REQUIRED: 'Start play() directly in a user tap handler before awaiting other work.',
        AUDIO_UNSUPPORTED: 'Check that the bundled file exists and uses a supported codec, such as PCM WAV.',
        AUDIO_LOAD_FAILED: 'Check the bundled asset path and package integrity; remote media is blocked.',
        AUDIO_DECODE_FAILED: 'The audio could not be decoded. Re-export the file as PCM WAV.',
        AUDIO_ABORTED: 'Playback was interrupted by pause(), load(), a source change, or navigation.',
        AUDIO_PLAY_FAILED: 'Playback failed. Check the asset, output volume, and system audio route.',
        AUDIO_POLICY_BLOCKED: 'Only audio bundled in this screen package may be loaded.'
      };
      const report = code => {
        console.error('[Screenpunk] ' + code + ': ' + messages[code]);
        window.webkit.messageHandlers.screenpunkAudioDiagnostic.postMessage(code);
        window.dispatchEvent(new CustomEvent('screenpunk:audio-error', { detail: { code, message: messages[code] } }));
      };
      const observed = new WeakSet();
      const original = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function (...args) {
        if (!observed.has(this)) {
          observed.add(this);
          this.addEventListener('error', () => report(
            ({ 1: 'AUDIO_ABORTED', 2: 'AUDIO_LOAD_FAILED', 3: 'AUDIO_DECODE_FAILED', 4: 'AUDIO_UNSUPPORTED' })[this.error?.code] || 'AUDIO_PLAY_FAILED'));
        }
        const result = original.apply(this, args);
        // Return a rejecting promise even when the screen chooses to catch it.
        // Report first, so a screen's empty catch cannot hide host diagnostics.
        return result.catch(error => {
          report(({ NotAllowedError: 'AUDIO_GESTURE_REQUIRED', NotSupportedError: 'AUDIO_UNSUPPORTED', AbortError: 'AUDIO_ABORTED' })[error.name] || 'AUDIO_PLAY_FAILED');
          throw error;
        });
      };
      document.addEventListener('securitypolicyviolation', event => {
        if (event.effectiveDirective === 'media-src') report('AUDIO_POLICY_BLOCKED');
      });
    })();
    """
}

@MainActor
private final class AudioDiagnostics: NSObject, WKScriptMessageHandler {
    static let logger = Logger(subsystem: "xyz.screenpunk", category: "BundledAudio")
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url?.absoluteString,
              url.hasPrefix("screenpunk://package/"),
              let code = message.body as? String else { return }
        // Only fixed messages reach the native log; never log arbitrary page data/URLs.
        switch code {
        case "AUDIO_GESTURE_REQUIRED": Self.logger.error("AUDIO_GESTURE_REQUIRED: Call play() synchronously from a tap handler.")
        case "AUDIO_UNSUPPORTED": Self.logger.error("AUDIO_UNSUPPORTED: Check the bundled path and codec; use PCM WAV.")
        case "AUDIO_LOAD_FAILED": Self.logger.error("AUDIO_LOAD_FAILED: Check the bundled asset path and package integrity.")
        case "AUDIO_DECODE_FAILED": Self.logger.error("AUDIO_DECODE_FAILED: Re-export the bundled audio as PCM WAV.")
        case "AUDIO_ABORTED": Self.logger.info("AUDIO_ABORTED: Playback was interrupted.")
        case "AUDIO_PLAY_FAILED": Self.logger.error("AUDIO_PLAY_FAILED: Check asset, output volume, and audio route.")
        case "AUDIO_POLICY_BLOCKED": Self.logger.error("AUDIO_POLICY_BLOCKED: Only package-local media is allowed.")
        default: break
        }
    }
}
