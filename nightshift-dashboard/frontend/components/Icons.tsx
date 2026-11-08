// The only icons: ones that carry meaning. Plain shapes, one stroke weight, colour comes from the text.

const base = { width: 18, height: 18, viewBox: "0 0 24 24", fill: "currentColor", "aria-hidden": true } as const;

export const WarningIcon = () => (
  <svg {...base}><path d="M12 2.5 1.5 21h21L12 2.5Zm-1 7h2v6h-2v-6Zm0 8h2v2h-2v-2Z" /></svg>
);
export const PlayIcon = () => (
  <svg {...base}><path d="M7 4.5v15l13-7.5-13-7.5Z" /></svg>
);
export const PauseIcon = () => (
  <svg {...base}><path d="M6 4h4v16H6V4Zm8 0h4v16h-4V4Z" /></svg>
);
