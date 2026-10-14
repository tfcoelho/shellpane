import React from 'react';
import {Exit} from '../components/Exit';
import {Words} from '../components/Words';
import {FPS} from '../theme';

// Starts on an empty stage: the logo has fully left before the first word rises.
export const HEADLINE_FRAMES = Math.round(2.7 * FPS);

export const HeadlineScene = () => (
  <Exit duration={HEADLINE_FRAMES} frames={16}>
    <div style={{width: 1500, display: 'flex', flexDirection: 'column', gap: 8}}>
      <Words text="The Mac file manager" size={104} delay={6} />
      <Words text="for people who live in SSH." size={104} delay={18} accent={[4, 5]} />
    </div>
  </Exit>
);
