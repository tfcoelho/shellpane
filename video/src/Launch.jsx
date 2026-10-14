import React from 'react';
import {Audio, AbsoluteFill, staticFile, useVideoConfig} from 'remotion';
import {TransitionSeries} from '@remotion/transitions';
import {Background} from './components/Background';
import {LogoScene, LOGO_FRAMES} from './scenes/LogoScene';
import {HeadlineScene, HEADLINE_FRAMES} from './scenes/HeadlineScene';
import {AppScene, APP_FRAMES} from './scenes/AppScene';
import {YoursScene, YOURS_FRAMES} from './scenes/YoursScene';
import {EndScene, END_FRAMES} from './scenes/EndScene';

// Scenes follow each other with no crossfade: each one leaves before the next arrives, so nothing overlaps.
export const LAUNCH_FRAMES = LOGO_FRAMES + HEADLINE_FRAMES + APP_FRAMES + YOURS_FRAMES + END_FRAMES;

export const Launch = ({music = null}) => {
  const {fps} = useVideoConfig();
  return (
    <AbsoluteFill>
      <Background />
      {music && <Audio src={staticFile(music)} />}
      <TransitionSeries>
        <TransitionSeries.Sequence name="Logo" durationInFrames={LOGO_FRAMES} premountFor={fps}><LogoScene /></TransitionSeries.Sequence>
        <TransitionSeries.Sequence name="Headline" durationInFrames={HEADLINE_FRAMES} premountFor={fps}><HeadlineScene /></TransitionSeries.Sequence>
        <TransitionSeries.Sequence name="The app" durationInFrames={APP_FRAMES} premountFor={fps}><AppScene /></TransitionSeries.Sequence>
        <TransitionSeries.Sequence name="Yours" durationInFrames={YOURS_FRAMES} premountFor={fps}><YoursScene /></TransitionSeries.Sequence>
        <TransitionSeries.Sequence name="End" durationInFrames={END_FRAMES} premountFor={fps}><EndScene /></TransitionSeries.Sequence>
      </TransitionSeries>
    </AbsoluteFill>
  );
};
