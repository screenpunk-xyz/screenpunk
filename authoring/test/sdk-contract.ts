import type { DashboardClient } from '../../sdk/src/client';
import type { ScreenpunkClient } from '../react/index';
declare const sdk: DashboardClient;
// Compile-time check: the adapter accepts the real SDK without another bridge.
const supported: ScreenpunkClient = sdk;
void supported;
