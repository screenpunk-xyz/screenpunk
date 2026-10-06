# Start the Mac CLI service

macOS may display a permission or security prompt during the first service start
after an install or update. Review it and approve the appropriate prompt for your
verified Screenpunk installation. An agent must surface a pending prompt early
and wait for you; it cannot dismiss or approve an OS prompt on your behalf.

After resolving a pending prompt, retry once with `screenpunk service start
--json`, outside the Codex sandbox through its normal approval flow, using the
same installing account without sudo. If it still fails, preserve the complete
command, JSON error, stdout/stderr and exit status. Collect `screenpunk service
logs --json` and `launchctl print gui/<your UID>/com.screenpunk.workbench` before
another start or recovery attempt. The UID must be the installing account's
effective UID. These diagnostics do not start the broker.

Keep activationError and cleanupError separate. One Studio 1.0.8 start reported
activationError=unavailable and cleanupError=insecureRuntime, then worked after
the user allowed a pending macOS prompt. The prompt text and precise cause were
not established; these errors do not identify a particular macOS permission.

Preserve the workspace, pairing, saved screen preferences and local drafts.
Do not reset them, change runtime permissions, delete sockets, bypass ownership
guards or delete Keychain entries to get past startup. Review the diagnostic
evidence before choosing a supported recovery.
