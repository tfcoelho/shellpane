import React from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {INK, clamp, fontFamily} from '../theme';

/**
 * A short label beside what to look at, instead of a subtitle at the bottom: the eye stays on the action.
 * `x`, `y`: the anchor on the canvas in pixels; `side`: where the label sits ("right", "left" or "below").
 * `from`, `to`: seconds. It rises in and fades; no blur.
 */
export const Note = ({from, to, x, y, text, side = 'right', gap = 26}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const t = frame / fps;
  if (t < from || t > to) return null;
  const enter = spring({frame: frame - from * fps, fps, config: {damping: 20, stiffness: 180}});
  const leave = interpolate(t, [to - 0.2, to], [1, 0], clamp);
  const place = {
    right: {left: x + gap, top: y, transform: 'translateY(-50%)'},
    left: {left: x - gap, top: y, transform: 'translate(-100%, -50%)'},
    below: {left: x, top: y + gap, transform: 'translateX(-50%)'},
  }[side];
  return (
    <div style={{
      position: 'absolute', ...place, opacity: Math.min(1, enter * 1.3) * leave,
      marginTop: (1 - enter) * 14, whiteSpace: 'nowrap',
      // One layer: a translucent dark fill, nothing around it.
      padding: '12px 22px', borderRadius: 14, background: 'rgba(18, 19, 21, 0.8)',
      fontFamily, fontSize: 32, fontWeight: 500, color: INK, letterSpacing: -0.3,
    }}>
      {text}
    </div>
  );
};
