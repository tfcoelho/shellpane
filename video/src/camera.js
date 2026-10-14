// How the camera behaves, in one place (owner's review: zooms were too fast and too deep to follow).
// - The full window is the default framing (zoom 1).
// - A lean-in is gentle: at most MAX_ZOOM, only for the moment worth seeing up close.
// - Every move takes at least MOVE seconds; between moves the camera holds still.
export const MAX_ZOOM = 1.3;
export const MOVE = 1.1;

export const full = {x: 0.5, y: 0.5, zoom: 1};
