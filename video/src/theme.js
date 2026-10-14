import {loadFont} from '@remotion/google-fonts/Inter';

export const {fontFamily} = loadFont('normal', {weights: ['400', '500', '600', '700'], subsets: ['latin']});
export const FPS = 60;
export const WIDTH = 1920;
export const HEIGHT = 1080;
// The video's background, flat at every edge. A web page section in this colour makes the video seamless.
export const BG = '#0c0d0f';
export const INK = '#f2f2f5';
export const MUTED = '#8a8a92';
export const MONO = 'ui-monospace, Menlo, monospace';
// Top to bottom, so every accented word has the same colours.
export const TEAL_GRADIENT = 'linear-gradient(180deg, #6fe3c8, #22b896)';
export const TEAL = '#4fd1b4';
export const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'};
export const MOTION_BLUR = true;
