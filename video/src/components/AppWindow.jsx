import React from 'react';
import {AbsoluteFill, Easing, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {Cursor} from './Cursor';
import {Note} from './Note';
import {MAX_ZOOM} from '../camera';
import {clamp} from '../theme';

// States were captured from a 1180×720-point window at 3×.
const ASPECT = 2160 / 3540;
const ease = Easing.inOut(Easing.sin);

/** The state showing at `frame`: the last whose `at` has passed, cutting in with a 3-frame dissolve. */
const Layered = ({states, frame, fps}) => {
  let index = 0;
  states.forEach((s, i) => { if (s.at * fps <= frame) index = i; });
  const current = states[index];
  const previous = index > 0 ? states[index - 1] : null;
  const dissolve = previous ? interpolate(frame, [current.at * fps, current.at * fps + 3], [0, 1], clamp) : 1;
  const img = (file, opacity) => (
    <Img key={file} src={staticFile(`states/${file}`)} style={{position: 'absolute', inset: 0, width: '100%', height: '100%', opacity}} />
  );
  return (
    <div style={{position: 'absolute', inset: 0}}>
      {previous && dissolve < 1 && img(previous.file, 1)}
      {img(current.file, dissolve)}
    </div>
  );
};

/**
 * Where the window goes on the canvas for one camera stop: its scale and offset. The camera moves the whole
 * window, frame and shadow included, as a camera over a desk would; it never crops inside the frame.
 * The focus point stays where it is at zoom 1 and comes to the middle of the frame at the deepest zoom.
 */
function place({x, y, zoom}, W, H, width, height) {
  const k = Math.min(1, Math.max(0, (zoom - 1) / (MAX_ZOOM - 1)));
  const X0 = (width - W) / 2;
  const Y0 = (height - H) / 2;
  const sx = X0 + x * W + (width / 2 - (X0 + x * W)) * k;
  const sy = Y0 + y * H + (height / 2 - (Y0 + y * H)) * k;
  // A window bigger than the frame never leaves more than MARGIN of background at an edge (centring
  // something near the window's edge would otherwise slide it half off screen); a smaller one stays centred.
  const fit = (pos, size, frame) => (size + 2 * MARGIN <= frame ? (frame - size) / 2
    : Math.min(MARGIN, Math.max(frame - size - MARGIN, pos)));
  return {s: zoom, left: fit(sx - x * W * zoom, W * zoom, width), top: fit(sy - y * H * zoom, H * zoom, height)};
}
const MARGIN = 60;

/** Where the window is on the canvas at this frame: its size, scale and offset, from the camera stops. */
export const useWindowPlacement = (camera) => {
  const frame = useCurrentFrame();
  const {fps, width, height} = useVideoConfig();
  const t = frame / fps;
  const W = Math.round(width * 0.8);
  const H = Math.round(W * ASPECT);
  const stops = camera.map((c) => ({t: c.t, ...place(c, W, H, width, height)}));
  const at = (key) => (stops.length === 1 ? stops[0][key]
    : interpolate(t, stops.map((c) => c.t), stops.map((c) => c[key]), {...clamp, easing: ease}));
  return {W, H, s: at('s'), left: at('left'), top: at('top')};
};

/**
 * Labels beside what to look at, placed with the window (same camera) but drawn outside its motion blur,
 * so they stay one crisp layer: [{from, to, x, y, text, side}] in window fractions.
 */
export const WindowNotes = ({camera, notes}) => {
  const {W, H, s, left, top} = useWindowPlacement(camera);
  return (
    <AbsoluteFill>
      {notes.map((n, i) => <Note key={i} {...n} x={left + n.x * W * s} y={top + n.y * H * s} />)}
    </AbsoluteFill>
  );
};

/**
 * The real app as a floating window.
 * - `states`: [{file, at}], `at` in seconds from the scene's start.
 * - `camera`: [{t, x, y, zoom}], x and y as fractions of the window. Between stops the window's scale and
 *   position move together, so every move is one straight, eased motion.
 * - `sheet`: {frame: [x, y, w, h] fractions of the window, from, to (seconds), states}: slides down from the
 *   title bar as a macOS sheet does, and back up when it closes.
 * - `cursor`: [{t, x, y, click?}] for the pointer, in window fractions.
 * - `intro`: the window tilts up into place. `exit`: {duration, frames}: it fades out at the scene's end.
 */
export const AppWindow = ({states, camera, sheet = null, cursor = null, intro = false, exit = null}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const t = frame / fps;
  const {W, H, s, left, top} = useWindowPlacement(camera);

  const rise = intro ? spring({frame, fps, config: {damping: 22, stiffness: 120}}) : 1;
  const fade = exit ? interpolate(frame, [exit.duration - exit.frames, exit.duration], [1, 0], clamp) : 1;

  let sheetLayer = null;
  if (sheet && t >= sheet.from && t <= sheet.to + 0.3) {
    const down = interpolate(t, [sheet.from, sheet.from + 0.32], [0, 1], {...clamp, easing: Easing.bezier(0.2, 0.9, 0.2, 1)});
    const up = interpolate(t, [sheet.to, sheet.to + 0.25], [0, 1], {...clamp, easing: Easing.in(Easing.cubic)});
    const shown = down * (1 - up);
    const [sx, sy, sw, sh] = sheet.frame;
    sheetLayer = (
      <div style={{position: 'absolute', left: sx * W, top: sy * H, width: sw * W, height: sh * H, overflow: 'hidden'}}>
        <div style={{
          position: 'absolute', inset: 0, transform: `translateY(${(shown - 1) * 100}%)`,
          boxShadow: '0 18px 50px rgba(0,0,0,0.55)', borderRadius: '0 0 12px 12px', overflow: 'hidden',
        }}>
          <Layered states={sheet.states} frame={frame} fps={fps} />
        </div>
      </div>
    );
  }

  return (
    <AbsoluteFill style={{perspective: 2400, opacity: fade}}>
      <div style={{
        position: 'absolute', left, top, width: W, height: H, transformOrigin: '0 0',
        transform: `scale(${s}) rotateX(${(1 - rise) * 24}deg) translateY(${(1 - rise) * 140}px) scale(${0.9 + 0.1 * rise})`,
        opacity: Math.min(1, rise * 1.6),
      }}>
        <div style={{
          position: 'absolute', inset: 0, borderRadius: 22, overflow: 'hidden',
          boxShadow: '0 50px 140px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.08)',
        }}>
          <Layered states={states} frame={frame} fps={fps} />
          {sheetLayer}
        </div>
        {cursor && <Cursor path={cursor} width={W} height={H} />}
      </div>
    </AbsoluteFill>
  );
};
