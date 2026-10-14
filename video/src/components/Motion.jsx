import React from 'react';
import {HtmlInCanvasMotionBlur} from '@remotion/motion-blur';
import {AbsoluteFill, useVideoConfig} from 'remotion';
import {MOTION_BLUR} from '../theme';

/** Camera-style motion blur on whatever moves inside (Remotion's HTML-in-canvas blur, 4.0.529+). */
export const Motion = ({children}) => {
  const {width, height} = useVideoConfig();
  if (!MOTION_BLUR) return <AbsoluteFill>{children}</AbsoluteFill>;
  return (
    // A short shutter and many samples: enough to soften a fast move, never enough to double the text.
    <HtmlInCanvasMotionBlur width={width} height={height} samples={14} shutterAngle={90}>
      <AbsoluteFill>{children}</AbsoluteFill>
    </HtmlInCanvasMotionBlur>
  );
};
