import type { DashboardClient } from '../../sdk/src/client';
import type { ScreenpunkClient } from '../react/index';
declare const sdk: DashboardClient;
// Compile-time check: the adapter accepts the real SDK without another bridge.
const supported: ScreenpunkClient = sdk;
void supported;

// Persistence remains the real injected SDK, with capability-aware optional use.
if (supported.state) {
  const restored: Promise<unknown> = supported.state.get('preferences.v1');
  const saved: Promise<void> = supported.state.set('preferences.v1', { schemaVersion: 1 });
  const reset: Promise<void> = supported.state.remove('preferences.v1');
  void [restored, saved, reset];
}
