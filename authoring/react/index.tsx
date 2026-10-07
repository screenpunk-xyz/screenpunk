import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';

/** Narrow structural view of sdk/src/client.ts; the host owns the bridge. */
export interface PublicReadResult<T = unknown> {
  state: 'fresh' | 'stale' | 'unavailable' | 'error'; status: number;
  data?: T; resourceURL?: string; fetchedAt?: string; lastModified?: string; retryAfterSeconds?: number; code?: string;
}
export interface ScreenpunkClient {
  runtime: { ready(): void; onStatus(listener: (status: unknown) => void): () => void };
  connections: {
    read(alias: string, operation: string, parameters?: Record<string, string>, options?: { signal?: AbortSignal }): Promise<PublicReadResult>;
    release(url: string): void;
    subscribe(alias: string, operation: string, parameters: Record<string, unknown>, listener: (message: unknown) => void): () => void;
  };
}
export interface RuntimeStatus { active?: boolean; publicReadHTTP?: number; [key: string]: unknown }
const Context = createContext<{ client?: ScreenpunkClient; status: RuntimeStatus; active: boolean }>({ status: {}, active: true });
const readied = new WeakSet<ScreenpunkClient>();
export function ScreenpunkProvider({ children, client = (globalThis as typeof globalThis & { screenpunk?: ScreenpunkClient }).screenpunk }: { children: ReactNode; client?: ScreenpunkClient }) {
  const [status, setStatus] = useState<RuntimeStatus>({});
  const [visible, setVisible] = useState(() => typeof document === 'undefined' || !document.hidden);
  useEffect(() => client?.runtime.onStatus?.(value => { if (value && typeof value === 'object') setStatus(value as RuntimeStatus); }), [client]);
  useEffect(() => {
    if (typeof document === 'undefined') return;
    const change = () => setVisible(!document.hidden);
    document.addEventListener('visibilitychange', change);
    return () => document.removeEventListener('visibilitychange', change);
  }, []);
  return <Context.Provider value={{ client, status, active: visible && status.active !== false }}>{children}</Context.Provider>;
}
export function useScreenpunk() { return useContext(Context).client; }
export function useRuntimeStatus() { return useContext(Context); }
export function useScreenReady() {
  const client = useScreenpunk();
  useEffect(() => { if (client && !readied.has(client)) { client.runtime.ready(); readied.add(client); } }, [client]);
}
function keyFor(parameters: Record<string, unknown>) {
  const stable = (value: unknown): unknown => Array.isArray(value) ? value.map(stable) : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).sort(([a],[b]) => a.localeCompare(b)).map(([k,v]) => [k,stable(v)])) : value;
  return JSON.stringify(stable(parameters));
}
export function usePublicRead<T>(alias: string, operation: string, parameters: Record<string, string> = {}, enabled = true) {
  const { client, active } = useRuntimeStatus();
  const key = keyFor(parameters);
  const params = useMemo(() => JSON.parse(key) as Record<string, string>, [key]);
  const [result, setResult] = useState<PublicReadResult<T> | { state: 'loading' | 'permission-required'; code?: string }>({ state: 'loading' });
  const [refresh, setRefresh] = useState(0);
  const retryAt = useRef(0);
  useEffect(() => { retryAt.current = 0; }, [alias, operation, key]);
  useEffect(() => {
    if (!enabled || !active) return;
    if (!client?.connections?.read) { setResult({ state: 'unavailable', status: 0, code: 'host_unavailable' }); return; }
    const abort = new AbortController(); let resource: string | undefined;
    const run = async () => {
      setResult({ state: 'loading' });
      try {
        const value = await client.connections.read(alias, operation, params, { signal: abort.signal }) as PublicReadResult<T>;
        if (abort.signal.aborted) { if (value.resourceURL) client.connections.release(value.resourceURL); return; }
        resource = value.resourceURL;
        retryAt.current = Date.now() + Math.max(0, value.retryAfterSeconds ?? 0) * 1000;
        setResult(value);
      } catch (error) {
        if (abort.signal.aborted) return;
        const code = (error as { code?: string }).code ?? 'read_failed';
        setResult(code === 'permission_required' ? { state: 'permission-required', code } : { state: 'error', status: 0, code });
      }
    };
    const timer = setTimeout(() => { void run(); }, Math.max(0, retryAt.current - Date.now()));
    return () => { clearTimeout(timer); abort.abort(); if (resource) client.connections.release(resource); };
  }, [client, active, enabled, alias, operation, params, refresh]);
  return { result, refresh: () => setRefresh(n => n + 1) };
}
export function useConnectionSubscription(alias: string, operation: string, parameters: Record<string, unknown>, listener: (message: unknown) => void, enabled = true) {
  const { client, active } = useRuntimeStatus();
  const callback = useRef(listener); callback.current = listener;
  const key = keyFor(parameters);
  useEffect(() => {
    if (client && active && enabled) return client.connections.subscribe(alias, operation, JSON.parse(key), value => callback.current(value));
  }, [client, active, enabled, alias, operation, key]);
}
