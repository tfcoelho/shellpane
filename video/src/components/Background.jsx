import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {BG} from '../theme';

const GLOW = 'ellipse 900px 520px at 50% 58%';

/**
 * A flat colour at every edge (BG: give the web page section the same colour and the video blends in), with
 * one soft teal glow that fades out well inside the frame.
 *
 * Dither: 8-bit video can only step the glow's brightness in whole levels, which shows as bands. A fine grain
 * of about ±2 levels, changing every frame like film grain, breaks the steps up so the eye sees a smooth
 * gradient. It's masked to the glow, so the edges stay perfectly flat.
 */
export const Background = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{background: BG}}>
      <AbsoluteFill style={{
        background: `radial-gradient(${GLOW}, rgba(22,177,146,0.20), rgba(22,177,146,0.07) 45%, rgba(22,177,146,0) 72%)`,
      }} />
      <svg width="100%" height="100%" style={{position: 'absolute', inset: 0, opacity: 0.08,
                                              WebkitMaskImage: `radial-gradient(${GLOW}, #000 55%, transparent 80%)`}}>
        <filter id="grain" x="0" y="0" width="100%" height="100%">
          <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="1" seed={frame % 97} stitchTiles="stitch" />
          <feColorMatrix type="saturate" values="0" />
        </filter>
        <rect width="100%" height="100%" filter="url(#grain)" />
      </svg>
    </AbsoluteFill>
  );
};
