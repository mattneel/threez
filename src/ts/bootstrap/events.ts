/**
 * Event class polyfills for QuickJS-NG.
 *
 * Provides Event, PointerEvent, WheelEvent, and KeyboardEvent
 * with the subset of properties that Three.js relies on.
 */

export interface EventInit {
  bubbles?: boolean;
  cancelable?: boolean;
}

export class Event {
  readonly type: string;
  readonly bubbles: boolean;
  readonly cancelable: boolean;
  readonly timeStamp: number;

  defaultPrevented: boolean = false;

  /** @internal set by EventTarget.dispatchEvent */
  _target: any = null;
  /** @internal set by EventTarget.dispatchEvent */
  _currentTarget: any = null;
  /** @internal */
  _stopProp: boolean = false;
  /** @internal */
  _stopImmediate: boolean = false;

  get target(): any {
    return this._target;
  }
  get currentTarget(): any {
    return this._currentTarget;
  }

  constructor(type: string, init?: EventInit) {
    this.type = type;
    this.bubbles = init?.bubbles ?? false;
    this.cancelable = init?.cancelable ?? false;
    this.timeStamp = Date.now();
  }

  preventDefault(): void {
    if (this.cancelable) {
      this.defaultPrevented = true;
    }
  }

  stopPropagation(): void {
    this._stopProp = true;
  }

  stopImmediatePropagation(): void {
    this._stopProp = true;
    this._stopImmediate = true;
  }
}

// ---------------------------------------------------------------------------
// PointerEvent
// ---------------------------------------------------------------------------

export interface PointerEventInit extends EventInit {
  clientX?: number;
  clientY?: number;
  movementX?: number;
  movementY?: number;
  button?: number;
  buttons?: number;
  pointerId?: number;
  pointerType?: string;
}

export class PointerEvent extends Event {
  readonly clientX: number;
  readonly clientY: number;
  readonly movementX: number;
  readonly movementY: number;
  readonly button: number;
  readonly buttons: number;
  readonly pointerId: number;
  readonly pointerType: string;

  constructor(type: string, init?: PointerEventInit) {
    super(type, init);
    this.clientX = init?.clientX ?? 0;
    this.clientY = init?.clientY ?? 0;
    this.movementX = init?.movementX ?? 0;
    this.movementY = init?.movementY ?? 0;
    this.button = init?.button ?? 0;
    this.buttons = init?.buttons ?? 0;
    this.pointerId = init?.pointerId ?? 0;
    this.pointerType = init?.pointerType ?? "";
  }
}

// ---------------------------------------------------------------------------
// WheelEvent
// ---------------------------------------------------------------------------

export interface WheelEventInit extends EventInit {
  deltaX?: number;
  deltaY?: number;
  deltaZ?: number;
  deltaMode?: number;
}

export class WheelEvent extends Event {
  readonly deltaX: number;
  readonly deltaY: number;
  readonly deltaZ: number;
  readonly deltaMode: number;

  constructor(type: string, init?: WheelEventInit) {
    super(type, init);
    this.deltaX = init?.deltaX ?? 0;
    this.deltaY = init?.deltaY ?? 0;
    this.deltaZ = init?.deltaZ ?? 0;
    this.deltaMode = init?.deltaMode ?? 0;
  }
}

// ---------------------------------------------------------------------------
// KeyboardEvent
// ---------------------------------------------------------------------------

export interface KeyboardEventInit extends EventInit {
  key?: string;
  code?: string;
  altKey?: boolean;
  ctrlKey?: boolean;
  metaKey?: boolean;
  shiftKey?: boolean;
  repeat?: boolean;
}

export class KeyboardEvent extends Event {
  readonly key: string;
  readonly code: string;
  readonly altKey: boolean;
  readonly ctrlKey: boolean;
  readonly metaKey: boolean;
  readonly shiftKey: boolean;
  readonly repeat: boolean;

  constructor(type: string, init?: KeyboardEventInit) {
    super(type, init);
    this.key = init?.key ?? "";
    this.code = init?.code ?? "";
    this.altKey = init?.altKey ?? false;
    this.ctrlKey = init?.ctrlKey ?? false;
    this.metaKey = init?.metaKey ?? false;
    this.shiftKey = init?.shiftKey ?? false;
    this.repeat = init?.repeat ?? false;
  }
}
