/**
 * fetch() polyfill for local filesystem and HTTP/HTTPS access.
 *
 * Uses native helpers registered by Zig:
 *   __native_readFileSync(path: string) -> Uint8Array | null
 *   __native_decodeBase64(data: string) -> Uint8Array | null
 *   __native_httpFetch(url: string) -> { status, statusText, contentType, body } | null
 *
 * Supports:
 *   - Local file paths (relative and absolute)
 *   - data: URIs (with optional base64 encoding)
 *   - HTTP/HTTPS URLs
 */

declare function __native_readFileSync(path: string): Uint8Array | null;
declare function __native_decodeBase64(data: string): Uint8Array | null;
declare function __native_httpFetch(
  url: string
): {
  status: number;
  statusText: string;
  contentType: string;
  body: Uint8Array;
} | null;

/** Guess content-type from file extension. */
function guessContentType(url: string): string {
  const dot = url.lastIndexOf(".");
  if (dot === -1) return "application/octet-stream";

  const ext = url.slice(dot).toLowerCase().split("?")[0].split("#")[0];

  switch (ext) {
    case ".json":
      return "application/json";
    case ".js":
    case ".mjs":
      return "application/javascript";
    case ".html":
    case ".htm":
      return "text/html";
    case ".css":
      return "text/css";
    case ".txt":
      return "text/plain";
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".svg":
      return "image/svg+xml";
    case ".glb":
      return "model/gltf-binary";
    case ".gltf":
      return "model/gltf+json";
    case ".wasm":
      return "application/wasm";
    case ".xml":
      return "application/xml";
    default:
      return "application/octet-stream";
  }
}

/** Minimal Headers implementation with get(). */
class FetchHeaders {
  private _map: Record<string, string> = {};

  constructor(init?: Record<string, string>) {
    if (init) {
      for (const key of Object.keys(init)) {
        this._map[key.toLowerCase()] = init[key];
      }
    }
  }

  get(name: string): string | null {
    return this._map[name.toLowerCase()] ?? null;
  }

  has(name: string): boolean {
    return name.toLowerCase() in this._map;
  }

  set(name: string, value: string): void {
    this._map[name.toLowerCase()] = value;
  }
}

/** Minimal Response implementation. */
class FetchResponse {
  readonly ok: boolean;
  readonly status: number;
  readonly statusText: string;
  readonly url: string;
  readonly headers: FetchHeaders;
  private _body: Uint8Array;

  constructor(
    body: Uint8Array,
    status: number,
    statusText: string,
    url: string,
    headers: Record<string, string>
  ) {
    this._body = body;
    this.ok = status >= 200 && status < 300;
    this.status = status;
    this.statusText = statusText;
    this.url = url;
    this.headers = new FetchHeaders(headers);
  }

  text(): Promise<string> {
    const bytes = this._body;
    // Convert Uint8Array to string.
    // TextDecoder is registered as a native polyfill and available at runtime,
    // but not in the TypeScript lib, so we use a dynamic check.
    const g = globalThis as any;
    if (typeof g.TextDecoder !== "undefined") {
      return Promise.resolve(new g.TextDecoder().decode(bytes));
    }
    // Fallback: manual conversion
    let str = "";
    for (let i = 0; i < bytes.length; i++) {
      str += String.fromCharCode(bytes[i]);
    }
    return Promise.resolve(str);
  }

  json(): Promise<any> {
    return this.text().then((t) => JSON.parse(t));
  }

  arrayBuffer(): Promise<ArrayBuffer> {
    const buf = this._body.buffer.slice(
      this._body.byteOffset,
      this._body.byteOffset + this._body.byteLength
    );
    return Promise.resolve(buf as ArrayBuffer);
  }

  blob(): Promise<any> {
    const g = globalThis as any;
    const contentType = this.headers.get("content-type") || "application/octet-stream";
    const blob = new g.Blob([this._body], { type: contentType });
    return Promise.resolve(blob);
  }
}

/** Decode percent-encoded string to bytes. */
function decodeURIBytes(str: string): Uint8Array {
  const parts: number[] = [];
  for (let i = 0; i < str.length; i++) {
    if (str[i] === "%" && i + 2 < str.length) {
      parts.push(parseInt(str.slice(i + 1, i + 3), 16));
      i += 2;
    } else {
      parts.push(str.charCodeAt(i));
    }
  }
  return new Uint8Array(parts);
}

/** Parse and fetch a data: URI. */
function fetchDataURI(url: string): FetchResponse {
  // data:[<mediatype>][;base64],<data>
  const rest = url.slice(5); // remove "data:"
  const commaIdx = rest.indexOf(",");
  if (commaIdx === -1) {
    return new FetchResponse(
      new Uint8Array(0),
      400,
      "Bad Request",
      url,
      { "content-type": "text/plain" }
    );
  }

  const meta = rest.slice(0, commaIdx);
  const data = rest.slice(commaIdx + 1);
  const isBase64 = meta.endsWith(";base64");
  const mediaType = isBase64 ? meta.slice(0, -7) : meta;
  const contentType = mediaType || "text/plain;charset=US-ASCII";

  let body: Uint8Array;
  if (isBase64) {
    const decoded =
      typeof __native_decodeBase64 === "function"
        ? __native_decodeBase64(data)
        : null;
    body = decoded ?? new Uint8Array(0);
  } else {
    body = decodeURIBytes(data);
  }

  return new FetchResponse(body, 200, "OK", url, {
    "content-type": contentType,
  });
}

/** Determine if a URL string represents a local file path. */
function isLocalPath(url: string): boolean {
  if (url.startsWith("./") || url.startsWith("../") || url.startsWith("/")) {
    return true;
  }
  // No protocol prefix => treat as local
  if (!url.includes("://") && !url.startsWith("data:")) {
    return true;
  }
  return false;
}

/** The fetch() polyfill. */
function fetchPolyfill(
  input: string | { url?: string; toString(): string }
): Promise<FetchResponse> {
  const url =
    typeof input === "string" ? input : input.url ?? input.toString();

  // blob: URL — look up from registry
  if (url.startsWith("blob:")) {
    const g = globalThis as any;
    const registry = g.__blobRegistry as Map<string, { data: Uint8Array; type: string }> | undefined;
    const entry = registry?.get(url);
    if (entry) {
      return Promise.resolve(
        new FetchResponse(entry.data, 200, "OK", url, {
          "content-type": entry.type,
        })
      );
    }
    return Promise.resolve(
      new FetchResponse(new Uint8Array(0), 404, "Not Found", url, {})
    );
  }

  // data: URI
  if (url.startsWith("data:")) {
    try {
      return Promise.resolve(fetchDataURI(url));
    } catch {
      return Promise.resolve(
        new FetchResponse(new Uint8Array(0), 400, "Bad Request", url, {})
      );
    }
  }

  // HTTP/HTTPS URL
  if (url.startsWith("http://") || url.startsWith("https://")) {
    if (typeof __native_httpFetch !== "function") {
      return Promise.resolve(
        new FetchResponse(
          new Uint8Array(0),
          0,
          "Network request not supported",
          url,
          {}
        )
      );
    }

    const result = __native_httpFetch(url);
    if (!result) {
      return Promise.resolve(
        new FetchResponse(
          new Uint8Array(0),
          0,
          "Network Error",
          url,
          {}
        )
      );
    }

    return Promise.resolve(
      new FetchResponse(
        result.body,
        result.status,
        result.statusText || "OK",
        url,
        {
          "content-type": result.contentType || "application/octet-stream",
        }
      )
    );
  }

  // Local file path
  if (isLocalPath(url)) {
    if (typeof __native_readFileSync !== "function") {
      return Promise.resolve(
        new FetchResponse(
          new Uint8Array(0),
          500,
          "Internal Error",
          url,
          {}
        )
      );
    }

    // Try CWD first, then resolve relative to script directory
    let bytes = __native_readFileSync(url);
    if (bytes === null && !url.startsWith("/")) {
      const scriptDir = (globalThis as any).__scriptDir;
      if (scriptDir) {
        // Resolve relative to the script's directory (e.g., examples/gltf_viewer/dist/)
        bytes = __native_readFileSync(scriptDir + "/" + url);
        // Also try one level up from dist/ (common pattern: script in dist/, assets alongside)
        if (bytes === null) {
          const parentDir = scriptDir.replace(/\/[^/]+\/?$/, "");
          if (parentDir !== scriptDir) {
            bytes = __native_readFileSync(parentDir + "/" + url);
          }
        }
      }
    }
    if (bytes === null) {
      return Promise.resolve(
        new FetchResponse(
          new Uint8Array(0),
          404,
          "Not Found",
          url,
          { "content-type": "text/plain" }
        )
      );
    }

    const contentType = guessContentType(url);
    return Promise.resolve(
      new FetchResponse(bytes, 200, "OK", url, {
        "content-type": contentType,
      })
    );
  }

  // Unsupported protocol
  return Promise.resolve(
    new FetchResponse(
      new Uint8Array(0),
      0,
      "Network request not supported",
      url,
      {}
    )
  );
}

/** Install fetch() and Response on globalThis. */
export function installFetch(): void {
  const g = globalThis as any;
  g.fetch = fetchPolyfill;
  g.Response = FetchResponse;
}
