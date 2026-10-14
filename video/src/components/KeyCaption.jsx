import React from 'react';
import {Sequence, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {INK, MONO, TEAL, clamp, fontFamily} from '../theme';

/** A key and what it does, as a pill over the bottom of the frame, from `start` to `end` seconds. */
export const KeyCaption = ({start, end, keyLabel, text}) => {
  const {fps} = useVideoConfig();
  return (
    <Sequence from={Math.round(start * fps)} durationInFrames={Math.round((end - start) * fps)} premountFor={fps} layout="none">
      <Pill keyLabel={keyLabel} text={text} length={Math.round((end - start) * fps)} />
    </Sequence>
  );
};

const Pill = ({keyLabel, text, length}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const enter = spring({frame, fps, config: {damping: 18, stiffness: 200}});
  const exit = interpolate(frame, [length - 8, length], [1, 0], clamp);
  return (
    <div style={{
      position: 'absolute', bottom: 64, left: '50%',
      transform: `translateX(-50%) translateY(${(1 - enter) * 26}px) scale(${0.94 + 0.06 * enter})`,
      opacity: Math.min(1, enter * 1.4) * exit, display: 'flex', alignItems: 'center', gap: 22,
      padding: '16px 30px 16px 16px', borderRadius: 999,
      background: 'rgba(14,14,16,0.86)', backdropFilter: 'blur(24px)',
      boxShadow: '0 20px 60px rgba(0,0,0,0.55), 0 0 0 1px rgba(255,255,255,0.1)',
      fontFamily, color: INK, fontSize: 40, fontWeight: 500, whiteSpace: 'nowrap',
    }}>
      {keyLabel && (
        <span style={{
          minWidth: 64, padding: '8px 20px', borderRadius: 14, textAlign: 'center',
          background: 'linear-gradient(#3a3a40, #2a2a2e)', boxShadow: 'inset 0 -3px 0 rgba(0,0,0,0.45), 0 0 0 1px rgba(255,255,255,0.14)',
          fontFamily: MONO, fontWeight: 600, fontSize: 36, color: TEAL,
        }}>{keyLabel}</span>
      )}
      <span>{text}</span>
    </div>
  );
};
