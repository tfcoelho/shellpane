import React from 'react';
import {Exit} from '../components/Exit';
import {Words} from '../components/Words';
import {FPS} from '../theme';

export const YOURS_FRAMES = Math.round(2.6 * FPS);

export const YoursScene = () => (
  <Exit duration={YOURS_FRAMES} frames={16}>
    <div style={{display: 'flex', flexDirection: 'column', gap: 4}}>
      <Words text="Your config." size={100} delay={6} />
      <Words text="Your agent." size={100} delay={18} />
      <Words text="Your keys." size={100} delay={30} accent={[0, 1]} />
    </div>
  </Exit>
);
