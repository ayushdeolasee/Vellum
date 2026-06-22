import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/** True when running on macOS. */
export const isMac =
  typeof navigator !== "undefined" &&
  /mac/i.test(navigator.platform || navigator.userAgent);

/**
 * The display label for the primary modifier key on the current platform:
 * "⌘" on macOS, "Ctrl" elsewhere.
 */
export const modKey = isMac ? "⌘" : "Ctrl";

/**
 * Formats a keyboard shortcut for display, using the platform-appropriate
 * modifier key. On macOS, "⌘O" (no separator); elsewhere "Ctrl+O".
 */
export function shortcut(key: string) {
  return isMac ? `${modKey}${key}` : `${modKey}+${key}`;
}
