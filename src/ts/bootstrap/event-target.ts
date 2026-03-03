/**
 * EventTarget polyfill for QuickJS-NG.
 *
 * Implements the DOM EventTarget interface with support for
 * capture, once, and passive listener options.
 */

import type { Event } from "./events";

interface ListenerEntry {
  callback: EventListenerOrEventListenerObject;
  capture: boolean;
  once: boolean;
  passive: boolean;
}

type EventListenerOrEventListenerObject =
  | ((event: Event) => void)
  | { handleEvent(event: Event): void };

interface AddEventListenerOptions {
  capture?: boolean;
  once?: boolean;
  passive?: boolean;
}

export class EventTarget {
  private _listeners: Map<string, ListenerEntry[]> = new Map();

  addEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: AddEventListenerOptions | boolean,
  ): void {
    if (callback === null) return;

    const { capture, once, passive } = normalizeOptions(options);

    let list = this._listeners.get(type);
    if (!list) {
      list = [];
      this._listeners.set(type, list);
    }

    // Deduplicate: same callback + same capture flag means duplicate
    const cb = callback;
    for (const entry of list) {
      if (entry.callback === cb && entry.capture === capture) {
        return;
      }
    }

    list.push({ callback: cb, capture, once, passive });
  }

  removeEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: AddEventListenerOptions | boolean,
  ): void {
    if (callback === null) return;

    const { capture } = normalizeOptions(options);

    const list = this._listeners.get(type);
    if (!list) return;

    for (let i = 0; i < list.length; i++) {
      if (list[i].callback === callback && list[i].capture === capture) {
        list.splice(i, 1);
        if (list.length === 0) {
          this._listeners.delete(type);
        }
        return;
      }
    }
  }

  dispatchEvent(event: Event): boolean {
    (event as any)._target = this;
    (event as any)._currentTarget = this;

    const list = this._listeners.get(event.type);
    if (!list) return !event.defaultPrevented;

    // Copy to avoid mutation during iteration
    const entries = list.slice();
    for (const entry of entries) {
      if ((event as any)._stopImmediate) break;

      if (entry.once) {
        this.removeEventListener(event.type, entry.callback, {
          capture: entry.capture,
        });
      }

      if (typeof entry.callback === "function") {
        entry.callback(event);
      } else {
        entry.callback.handleEvent(event);
      }
    }

    return !event.defaultPrevented;
  }
}

function normalizeOptions(
  options?: AddEventListenerOptions | boolean,
): { capture: boolean; once: boolean; passive: boolean } {
  if (typeof options === "boolean") {
    return { capture: options, once: false, passive: false };
  }
  return {
    capture: options?.capture ?? false,
    once: options?.once ?? false,
    passive: options?.passive ?? false,
  };
}
