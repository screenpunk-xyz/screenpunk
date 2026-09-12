import { MAX_STATE_KEY_BYTES, STATE_CACHE_BYTES } from "./limits.js";

export interface CacheRecord {
  value: unknown;
  fetchedAtMs: number;
  stale: boolean;
  write: boolean;
}

export class DashboardStore {
  private state = new Map<string, unknown>();
  private cache = new Map<string, CacheRecord>();
  private bytes = 0;

  constructor(readonly dashboardId: string) {}

  get(key: string): unknown {
    assertKey(key);
    return this.state.has(key) ? this.state.get(key) : null;
  }

  set(key: string, value: unknown): void {
    assertKey(key);
    const encoded = measure(key, value);
    const previous = this.state.has(key) ? measure(key, this.state.get(key)) : 0;
    this.ensureBudget(encoded - previous);
    this.state.set(key, value);
    this.bytes += encoded - previous;
  }

  remove(key: string): void {
    assertKey(key);
    if (!this.state.has(key)) return;
    this.bytes -= measure(key, this.state.get(key));
    this.state.delete(key);
  }

  rememberRead(cacheKey: string, value: unknown, fetchedAtMs: number): void {
    if (this.cache.get(cacheKey)?.write) {
      throw new Error("never cache a write as a read");
    }
    const encoded = measure(cacheKey, value);
    const previous = this.cache.has(cacheKey) ? measure(cacheKey, this.cache.get(cacheKey)?.value) : 0;
    this.ensureBudget(encoded - previous);
    this.cache.set(cacheKey, { value, fetchedAtMs, stale: false, write: false });
    this.bytes += encoded - previous;
  }

  markStale(cacheKey: string): CacheRecord | null {
    const record = this.cache.get(cacheKey);
    if (!record || record.write) return null;
    record.stale = true;
    return record;
  }

  readCache(cacheKey: string): CacheRecord | null {
    return this.cache.get(cacheKey) ?? null;
  }

  rejectWriteCache(cacheKey: string): void {
    this.cache.set(cacheKey, { value: null, fetchedAtMs: 0, stale: false, write: true });
  }

  clear(): void {
    this.state.clear();
    this.cache.clear();
    this.bytes = 0;
  }

  usedBytes(): number {
    return this.bytes;
  }

  static cacheKey(alias: string, operation: string, parameters: unknown): string {
    return `${alias}\u001f${operation}\u001f${stable(parameters)}`;
  }

  private ensureBudget(delta: number): void {
    if (this.bytes + delta > STATE_CACHE_BYTES) {
      throw new Error("size_limit");
    }
  }
}

function assertKey(key: string): void {
  if (!key || Buffer.byteLength(key) > MAX_STATE_KEY_BYTES) {
    throw new Error("validation_failed");
  }
}

function measure(key: string, value: unknown): number {
  return Buffer.byteLength(key) + Buffer.byteLength(JSON.stringify(value ?? null));
}

function stable(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  const obj = value as Record<string, unknown>;
  return `{${Object.keys(obj)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${stable(obj[k])}`)
    .join(",")}}`;
}
