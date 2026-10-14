import React from 'react';
import {LogoLockup} from '../components/Logo';
import {Exit} from '../components/Exit';
import {FPS} from '../theme';

export const LOGO_FRAMES = Math.round(2.2 * FPS);

export const LogoScene = () => (
  <Exit duration={LOGO_FRAMES} frames={16}><LogoLockup wordAt={36} /></Exit>
);
