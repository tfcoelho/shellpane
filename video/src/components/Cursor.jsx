import React from 'react';
import {Easing, interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {clamp} from '../theme';

const glide = Easing.inOut(Easing.cubic);

/**
 * A Mac pointer that moves between points and clicks, drawn in window coordinates so it zooms with the app.
 * `path`: [{t, x, y, click?}] with t in seconds from the scene's start and x, y as fractions of the window.
 * Between two points it glides; at a point with `click`, it presses and a soft ring spreads.
 */
export const Cursor = ({path, width, height, hideAfter = Infinity}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const t = frame / fps;
  if (t > hideAfter) return null;

  const times = path.map((p) => p.t);
  const at = (key) => (path.length === 1 ? path[0][key] : interpolate(t, times, path.map((p) => p[key]), {...clamp, easing: glide}));
  const x = at('x') * width;
  const y = at('y') * height;

  // The most recent click, if it's still playing.
  const click = path.filter((p) => p.click && p.t <= t).pop();
  const since = click ? t - click.t : Infinity;
  const press = since < 0.18 ? interpolate(since, [0, 0.08, 0.18], [1, 0.82, 1], clamp) : 1;
  const ring = since < 0.5 ? interpolate(since, [0, 0.5], [0, 1], clamp) : null;
  const appear = interpolate(t, [times[0], times[0] + 0.25], [0, 1], clamp);
  const size = height * 0.034;   // a pointer is about 24 points tall on a 720-point window

  return (
    <div style={{position: 'absolute', left: 0, top: 0, width, height, pointerEvents: 'none', opacity: appear}}>
      {ring !== null && (
        <div style={{
          position: 'absolute', left: x, top: y, width: size * 2.4, height: size * 2.4, borderRadius: '50%',
          transform: `translate(-50%, -50%) scale(${0.3 + ring * 0.9})`,
          border: `${size * 0.09}px solid rgba(79, 209, 180, ${0.9 * (1 - ring)})`,
          background: `rgba(79, 209, 180, ${0.18 * (1 - ring)})`,
        }} />
      )}
      <svg width={size} height={size * 1.5} viewBox="0 0 16 24"
           style={{position: 'absolute', left: x, top: y, transform: `translate(-2px, -1px) scale(${press})`,
                   transformOrigin: '2px 1px', filter: 'drop-shadow(0 2px 3px rgba(0,0,0,0.45))', overflow: 'visible'}}>
        {/* The classic arrow: black with a white outline, drawn for this video. */}
        <path d="M1 1 L1 18.5 L5.4 14.4 L8.3 21.2 L11.2 20 L8.4 13.3 L14.4 13.3 Z"
              fill="#111" stroke="#fff" strokeWidth="1.4" strokeLinejoin="round" />
      </svg>
    </div>
  );
};
