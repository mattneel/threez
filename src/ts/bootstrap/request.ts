/**
 * Request and Headers polyfills for QuickJS-NG.
 *
 * Three.js FileLoader.load() creates Request objects for fetch calls.
 * This minimal implementation provides enough surface area for
 * Three.js init and basic file loading to succeed.
 */

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

export class Headers {
  private _map: Map<string, string> = new Map();

  constructor(init?: Record<string, string> | Headers) {
    if (init) {
      if (init instanceof Headers) {
        init.forEach((value, name) => {
          this._map.set(name.toLowerCase(), value);
        });
      } else {
        for (const key of Object.keys(init)) {
          this._map.set(key.toLowerCase(), init[key]);
        }
      }
    }
  }

  append(name: string, value: string): void {
    const key = name.toLowerCase();
    const existing = this._map.get(key);
    if (existing !== undefined) {
      this._map.set(key, existing + ", " + value);
    } else {
      this._map.set(key, value);
    }
  }

  get(name: string): string | null {
    return this._map.get(name.toLowerCase()) ?? null;
  }

  set(name: string, value: string): void {
    this._map.set(name.toLowerCase(), value);
  }

  has(name: string): boolean {
    return this._map.has(name.toLowerCase());
  }

  delete(name: string): void {
    this._map.delete(name.toLowerCase());
  }

  forEach(callback: (value: string, name: string, headers: Headers) => void): void {
    this._map.forEach((value, name) => {
      callback(value, name, this);
    });
  }

  entries(): IterableIterator<[string, string]> {
    return this._map.entries();
  }

  keys(): IterableIterator<string> {
    return this._map.keys();
  }

  values(): IterableIterator<string> {
    return this._map.values();
  }

  [Symbol.iterator](): IterableIterator<[string, string]> {
    return this._map.entries();
  }
}

// ---------------------------------------------------------------------------
// Request
// ---------------------------------------------------------------------------

interface RequestInit {
  method?: string;
  headers?: Record<string, string> | Headers;
  body?: any;
  signal?: any;
  mode?: string;
  credentials?: string;
  cache?: string;
  redirect?: string;
  referrer?: string;
  integrity?: string;
}

export class Request {
  readonly url: string;
  readonly method: string;
  readonly headers: Headers;
  readonly signal: any;
  readonly mode: string;
  readonly credentials: string;
  readonly cache: string;
  readonly redirect: string;
  readonly referrer: string;
  readonly integrity: string;
  readonly body: any;

  constructor(input: string | Request, init?: RequestInit) {
    if (typeof input === "string") {
      this.url = input;
    } else {
      this.url = input.url;
    }

    this.method = init?.method ?? "GET";
    this.headers = new Headers(init?.headers);
    this.signal = init?.signal ?? null;
    this.mode = init?.mode ?? "cors";
    this.credentials = init?.credentials ?? "same-origin";
    this.cache = init?.cache ?? "default";
    this.redirect = init?.redirect ?? "follow";
    this.referrer = init?.referrer ?? "about:client";
    this.integrity = init?.integrity ?? "";
    this.body = init?.body ?? null;
  }

  clone(): Request {
    return new Request(this.url, {
      method: this.method,
      headers: this.headers,
      body: this.body,
      signal: this.signal,
    });
  }
}

// ---------------------------------------------------------------------------
// Install on globalThis
// ---------------------------------------------------------------------------

export function installRequest(): void {
  const g = globalThis as any;
  g.Headers = Headers;
  g.Request = Request;
}
