import React from 'react';
import {Easing, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {INK, clamp, fontFamily} from '../theme';

// The app icon (design/icon/make_icon.py, variant B), drawn in the same 1024 grid so it can move:
// a light pane (your Mac), a teal pane (the server), and the prompt chevron between them.
const PANE = {w: 220, h: 470, gap: 156, r: 30};
const LEFT_X = 512 - PANE.gap / 2 - PANE.w;
const RIGHT_X = 512 + PANE.gap / 2;
const TOP = 512 - PANE.h / 2;
const CHEVRON = {cx: 512 - 70 * 0.08, h: 140, w: 70, stroke: 44};
const CHEVRON_PATH = `M${CHEVRON.cx - CHEVRON.w / 2} ${512 - CHEVRON.h / 2} L${CHEVRON.cx + CHEVRON.w / 2} 512 L${CHEVRON.cx - CHEVRON.w / 2} ${512 + CHEVRON.h / 2}`;
const CHEVRON_LENGTH = 2 * Math.hypot(CHEVRON.w, CHEVRON.h / 2);

// Frames at 60 fps. The chevron is hidden until it starts drawing: a round line cap on a zero-length
// dash still paints a dot, which is what showed at the very start before.
const T = {body: 0, left: 6, right: 10, drawFrom: 16, drawTo: 34, glow: [26, 44, 80]};

export const Icon = ({size = 300, animate = true}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const f = animate ? frame : 10000;
  const body = spring({frame: f - T.body, fps, config: {damping: 15, stiffness: 160}});
  const left = spring({frame: f - T.left, fps, config: {damping: 18, stiffness: 170}});
  const right = spring({frame: f - T.right, fps, config: {damping: 18, stiffness: 170}});
  const draw = interpolate(f, [T.drawFrom, T.drawTo], [CHEVRON_LENGTH, 0], {...clamp, easing: Easing.bezier(0.33, 0, 0.2, 1)});
  const chevronVisible = f > T.drawFrom ? 1 : 0;
  const glow = interpolate(f, T.glow, [0, 0.6, 0.32], clamp);

  return (
    <div style={{position: 'relative', width: size, height: size}}>
      <div style={{
        position: 'absolute', inset: '14%', borderRadius: '30%', background: '#16b192',
        filter: `blur(${size * 0.18}px)`, opacity: glow,
      }} />
      <svg viewBox="0 0 1024 1024" width={size} height={size} style={{position: 'absolute', inset: 0, overflow: 'visible'}}>
        <defs>
          <linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#2e2e33" /><stop offset="1" stopColor="#17171a" /></linearGradient>
          <linearGradient id="mac" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#f6f6f9" /><stop offset="1" stopColor="#d9d9e0" /></linearGradient>
          <linearGradient id="server" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#16b192" /><stop offset="1" stopColor="#0b8470" /></linearGradient>
        </defs>
        <g style={{transform: `scale(${0.7 + 0.3 * body})`, transformOrigin: '512px 512px', opacity: Math.min(1, body * 2)}}>
          <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#body)" />
          <rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="#fff" strokeOpacity="0.12" strokeWidth="3" />
        </g>
        <rect x={LEFT_X} y={TOP} width={PANE.w} height={PANE.h} rx={PANE.r} fill="url(#mac)"
              style={{transform: `translateX(${(1 - left) * -150}px)`, opacity: Math.min(1, left * 1.5)}} />
        <rect x={RIGHT_X} y={TOP} width={PANE.w} height={PANE.h} rx={PANE.r} fill="url(#server)"
              style={{transform: `translateX(${(1 - right) * 150}px)`, opacity: Math.min(1, right * 1.5)}} />
        <path d={CHEVRON_PATH} fill="none" stroke="#f2f2f5" strokeWidth={CHEVRON.stroke}
              strokeLinecap="round" strokeLinejoin="round" opacity={chevronVisible}
              strokeDasharray={CHEVRON_LENGTH} strokeDashoffset={draw} />
      </svg>
    </div>
  );
};

/** Icon reveal, then the icon makes room and the wordmark slides in beside it. `wordAt` in frames. */
export const LogoLockup = ({iconSize = 280, fontSize = 112, wordAt = 40}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const open = spring({frame: frame - wordAt, fps, config: {damping: 20, stiffness: 140}});
  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 34 * open}}>
      <Icon size={iconSize} />
      <div style={{
        fontFamily, fontWeight: 600, fontSize, letterSpacing: -fontSize * 0.025, color: INK,
        width: fontSize * 5.3 * open, overflow: 'hidden', whiteSpace: 'nowrap',
        opacity: open, filter: `blur(${(1 - open) * 10}px)`,
      }}>
        Shellpane
      </div>
    </div>
  );
};
