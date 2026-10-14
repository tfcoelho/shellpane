import React from 'react';
import {AbsoluteFill, Composition, Folder} from 'remotion';
import {Launch, LAUNCH_FRAMES} from './Launch';
import {Background} from './components/Background';
import {FPS, HEIGHT, WIDTH} from './theme';
import {LogoScene, LOGO_FRAMES} from './scenes/LogoScene';
import {HeadlineScene, HEADLINE_FRAMES} from './scenes/HeadlineScene';
import {AppScene, APP_FRAMES} from './scenes/AppScene';
import {YoursScene, YOURS_FRAMES} from './scenes/YoursScene';
import {EndScene, END_FRAMES} from './scenes/EndScene';

// Each scene on its own, on the same background, so it can be previewed and timed alone in Studio.
const alone = (Scene) => () => (<AbsoluteFill><Background /><Scene /></AbsoluteFill>);
const scene = (id, Scene, frames) => (
  <Composition id={id} component={alone(Scene)} durationInFrames={frames} fps={FPS} width={WIDTH} height={HEIGHT} />
);

// 1920×1080 at 60 fps. To add music, put a licensed track in public/ and render with --props='{"music":"music.mp3"}'.
export const Root = () => (
  <>
    <Composition id="Launch" component={Launch} durationInFrames={LAUNCH_FRAMES} fps={FPS} width={WIDTH} height={HEIGHT}
                 defaultProps={{music: null}} />
    <Folder name="Scenes">
      {scene('Logo', LogoScene, LOGO_FRAMES)}
      {scene('Headline', HeadlineScene, HEADLINE_FRAMES)}
      {scene('TheApp', AppScene, APP_FRAMES)}
      {scene('Yours', YoursScene, YOURS_FRAMES)}
      {scene('End', EndScene, END_FRAMES)}
    </Folder>
  </>
);
