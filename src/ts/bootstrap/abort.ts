/**
 * AbortController / AbortSignal polyfill for QuickJS-NG.
 *
 * Three.js FileLoader creates AbortController instances for request
 * cancellation. This minimal implementation provides enough surface
 * area for Three.js init and basic file loading to succeed.
 */

import { EventTarget } from "./event-target";
import { Event } from "./events";

// ---------------------------------------------------------------------------
// AbortSignal
// ---------------------------------------------------------------------------

export class AbortSignal extends EventTarget {
  aborted: boolean = false;
  reason: any = undefined;

  // Callback-style handler (used by some code paths)
  onabort: ((this: AbortSignal, event: Event) => void) | null = null;

  throwIfAborted(): void {
    if (this.aborted) {
      throw this.reason;
    }
  }

  /** Internal: mark this signal as aborted and fire the abort event. */
  _abort(reason?: any): void {
    if (this.aborted) return;
    this.aborted = true;
    this.reason = reason ?? new DOMException("The operation was aborted.", "AbortError");
    const event = new Event("abort");
    if (this.onabort) this.onabort.call(this, event);
    this.dispatchEvent(event);
  }

  static abort(reason?: any): AbortSignal {
    const signal = new AbortSignal();
    signal._abort(reason ?? new DOMException("The operation was aborted.", "AbortError"));
    return signal;
  }

  static timeout(ms: number): AbortSignal {
    const signal = new AbortSignal();
    // In a real browser this would use setTimeout; we stub it as
    // QuickJS does not have timers wired for this yet.
    void ms;
    return signal;
  }

  static any(signals: AbortSignal[]): AbortSignal {
    const combined = new AbortSignal();
    for (const s of signals) {
      if (s.aborted) {
        combined._abort(s.reason);
        return combined;
      }
    }
    for (const s of signals) {
      s.addEventListener("abort", () => {
        combined._abort(s.reason);
      }, { once: true });
    }
    return combined;
  }
}

// ---------------------------------------------------------------------------
// DOMException (minimal, needed by AbortSignal)
// ---------------------------------------------------------------------------

class DOMException extends Error {
  readonly name: string;
  readonly code: number;

  constructor(message?: string, name?: string) {
    super(message ?? "");
    this.name = name ?? "Error";
    this.code = 0;
  }
}

// ---------------------------------------------------------------------------
// AbortController
// ---------------------------------------------------------------------------

export class AbortController {
  readonly signal: AbortSignal;

  constructor() {
    this.signal = new AbortSignal();
  }

  abort(reason?: any): void {
    (this.signal as AbortSignal)._abort(reason);
  }
}

// ---------------------------------------------------------------------------
// Install on globalThis
// ---------------------------------------------------------------------------

export function installAbort(): void {
  const g = globalThis as any;
  g.AbortController = AbortController;
  g.AbortSignal = AbortSignal;
  g.DOMException = DOMException;
}
