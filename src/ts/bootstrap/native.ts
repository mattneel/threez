/**
 * Type declarations for the __native global bridge.
 *
 * These functions are registered by Zig into the QuickJS context
 * before bootstrap.js runs. The actual implementations will be
 * wired up in later tickets; for now this file serves as the
 * typed contract between TypeScript and Zig.
 */

export interface NativeBridge {
  /** Request the pre-created GPU adapter (returns an opaque handle ID). */
  gpuRequestAdapter?(): number;
  /** Request the pre-created GPU device (returns an opaque handle ID). */
  gpuRequestDevice?(adapterId: number): number;
  /** Get the pre-created queue for a device (returns an opaque handle ID). */
  gpuGetQueue?(deviceId: number): number;

  /** Get the current window/surface dimensions. */
  getWindowWidth?(): number;
  getWindowHeight?(): number;
  getDevicePixelRatio?(): number;

  /** Request the next animation frame. */
  requestAnimationFrame?(callback: (time: number) => void): number;
  cancelAnimationFrame?(id: number): void;

  /** Logging bridge. */
  log?(level: string, ...args: unknown[]): void;

  /** Read a file synchronously, returning raw bytes or null on failure. */
  readFileSync?(path: string): Uint8Array | null;

  /** Decode a base64 string to raw bytes, or null on invalid input. */
  decodeBase64?(data: string): Uint8Array | null;
}

/**
 * The __native global, if registered by the Zig host.
 * May be undefined if bootstrap is evaluated in a plain QuickJS context
 * without native bindings (e.g., during testing).
 */
declare const __native: NativeBridge | undefined;

export function getNative(): NativeBridge | undefined {
  return typeof __native !== "undefined" ? __native : undefined;
}
