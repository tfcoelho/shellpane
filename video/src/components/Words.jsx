import React from 'react';
import {spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {INK, TEAL_GRADIENT, fontFamily} from '../theme';

/** Words that rise in one after another, `stagger` frames apart. `accent` word indexes get the teal gradient. */
export const Words = ({text, size, delay = 0, stagger = 3, accent = [], weight = 700}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  return (
    <div style={{display: 'flex', flexWrap: 'wrap', justifyContent: 'center', gap: `0 ${size * 0.26}px`}}>
      {text.split(' ').map((word, i) => {
        const s = spring({frame: frame - delay - i * stagger, fps, config: {damping: 22, stiffness: 160}});
        const teal = accent.includes(i);
        return (
          <span key={i} style={{
            fontFamily, fontSize: size, fontWeight: weight, letterSpacing: -size * 0.03, lineHeight: 1.1,
            color: teal ? 'transparent' : INK, backgroundImage: teal ? TEAL_GRADIENT : 'none',
            WebkitBackgroundClip: teal ? 'text' : 'border-box', display: 'inline-block',
            // Opacity and a short rise, as Apple does: no blur.
            opacity: Math.min(1, s * 1.3), transform: `translateY(${(1 - s) * size * 0.35}px)`,
          }}>{word}</span>
        );
      })}
    </div>
  );
};
