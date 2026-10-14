import React from 'react';
import {AbsoluteFill, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {LogoLockup} from '../components/Logo';
import {FPS, MONO, MUTED, TEAL, fontFamily} from '../theme';

export const END_FRAMES = Math.round(3.4 * FPS);

export const EndScene = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const line = spring({frame: frame - 44, fps, config: {damping: 20, stiffness: 150}});
  const small = spring({frame: frame - 60, fps, config: {damping: 20, stiffness: 150}});
  return (
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 44}}>
      <LogoLockup wordAt={30} />
      <div style={{
        fontFamily, fontSize: 56, fontWeight: 500, color: '#c9c9cf', letterSpacing: -1,
        opacity: line, transform: `translateY(${(1 - line) * 20}px)`,
      }}>
        If <span style={{fontFamily: MONO, color: TEAL}}>ssh</span> works, Shellpane works.
      </div>
      <div style={{fontFamily, fontSize: 30, color: MUTED, opacity: small}}>For macOS 14 and later</div>
    </AbsoluteFill>
  );
};
