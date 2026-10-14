import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {clamp} from '../theme';

/** Fades its scene (`duration` frames long) out over the last `frames`, so the next one starts on an empty
 *  stage: nothing overlaps. */
export const Exit = ({duration, frames = 14, children, style}) => {
  const frame = useCurrentFrame();
  const o = interpolate(frame, [duration - frames, duration], [1, 0], clamp);
  return <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', opacity: o, ...style}}>{children}</AbsoluteFill>;
};
