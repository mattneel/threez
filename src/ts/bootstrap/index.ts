/**
 * Bootstrap entry point for the threez runtime.
 *
 * This file is bundled into a single IIFE by esbuild and injected
 * into QuickJS-NG before any user code runs. It sets up the browser
 * API polyfills that Three.js expects.
 */

import { EventTarget } from "./event-target";
import { Event, PointerEvent, WheelEvent, KeyboardEvent } from "./events";
import { createDOM } from "./dom";

// Create the wired-up DOM instances
const dom = createDOM();

// Assign to globalThis so user code sees browser-like globals
const g = globalThis as any;

g.window = dom.window;
g.document = dom.document;
g.navigator = dom.navigator;
g.self = dom.window;

// Event constructors
g.Event = Event;
g.PointerEvent = PointerEvent;
g.WheelEvent = WheelEvent;
g.KeyboardEvent = KeyboardEvent;
g.EventTarget = EventTarget;

// window-level convenience aliases
g.requestAnimationFrame = (cb: (time: number) => void) =>
  dom.window.requestAnimationFrame(cb);
g.cancelAnimationFrame = (id: number) =>
  dom.window.cancelAnimationFrame(id);
g.innerWidth = dom.window.innerWidth;
g.innerHeight = dom.window.innerHeight;
g.devicePixelRatio = dom.window.devicePixelRatio;
