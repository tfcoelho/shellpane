import React from 'react';
import {AbsoluteFill} from 'remotion';
import {AppWindow, WindowNotes} from '../components/AppWindow';
import {Motion} from '../components/Motion';
import {SHEET_FRAME, sheetOf, state} from '../states';
import {PLACES as P} from '../places';
import {full} from '../camera';
import {FPS} from '../theme';

// One continuous shot: the organised sidebar, adding a server, where it went, then arranging panes and sending
// files to one of them. Labels sit beside what to look at (no subtitles), and the camera moves the whole window,
// one straight eased move per change.
const TOUR = 2.0;               // the whole window, the pointer reading down the sidebar
const PLUS = TOUR + 0.7;        // click +
const OPEN = PLUS + 0.2;        // the sheet drops down; the camera leans toward it, once
const SERVER = OPEN + 0.9;      // click the Server field, then two typing steps
const NAME = SERVER + 0.9;      // click Name, then two typing steps
const COLOUR = NAME + 0.9;      // pink (blue was the default)
const ICON = COLOUR + 0.7;      // the cart (the server icon was the default)
const CONNECT = ICON + 0.8;
const CLOSE = CONNECT + 0.2;    // the sheet goes up
const ADDED = CLOSE + 0.3;      // in the sidebar, open on the right
const ARRIVE = ADDED + 1.0;     // the pointer reaches the new row; the camera shows the whole window
const SPLIT = ARRIVE + 1.0;     // New Pane: a third pane, showing the start page
const THIRD = SPLIT + 1.0;      // Production opens in it, from the sidebar
const GRAB = THIRD + 0.7;       // pick it up by its path bar
const DROP = GRAB + 1.1;        // at the bottom edge, the preview lit: two on top, one below
const SELECT = DROP + 0.6;      // a file on the Mac
const TRANSFER = SELECT + 0.7;  // the app dims, the panes that can take it stay lit
const HOVER = TRANSFER + 0.8;   // the bottom pane lights up
const CHOOSE = HOVER + 0.5;     // the file lands there
export const APP_SECONDS = CHOOSE + 1.4;
export const APP_FRAMES = Math.round(APP_SECONDS * FPS);

// One lean-in for the whole sheet, one move back out.
const sheetView = {x: 0.56, y: 0.52, zoom: 1.2};
const CAMERA = [
  {t: 0, ...full},
  {t: OPEN, ...full},
  {t: OPEN + 1.1, ...sheetView},
  {t: CLOSE, ...sheetView},
  {t: ARRIVE + 0.1, ...full},        // back to the whole window: the new row and the server it opened
];

export const AppScene = () => (
  <AbsoluteFill>
    <Motion>
      <AppWindow
        intro
        exit={{duration: APP_FRAMES, frames: 16}}
        states={[
          {...state('overview'), at: 0},
          {...state('added'), at: ADDED},
          {...state('split'), at: SPLIT + 0.05},
          {...state('third'), at: THIRD + 0.05},
          {...state('drag'), at: GRAB + 0.6},
          {...state('landed'), at: DROP},
          {...state('selected'), at: SELECT + 0.05},
          {...state('picker'), at: TRANSFER + 0.05},
          {...state('picker-hover'), at: HOVER - 0.1},
          {...state('sent'), at: CHOOSE + 0.1},
        ]}
        sheet={{frame: SHEET_FRAME, from: OPEN, to: CLOSE, states: [
          {...sheetOf(state('form-empty')), at: 0},
          {...sheetOf(state('form-host', 0)), at: SERVER + 0.25},
          {...sheetOf(state('form-host', 1)), at: SERVER + 0.55},
          {...sheetOf(state('form-name', 0)), at: NAME + 0.25},
          {...sheetOf(state('form-name', 1)), at: NAME + 0.55},
          {...sheetOf(state('form-colour')), at: COLOUR + 0.05},
          {...sheetOf(state('form-icon')), at: ICON + 0.05},
        ]}}
        camera={CAMERA}
        cursor={[
          {t: 0.7, x: 0.34, y: 0.22},
          {t: 1.5, x: 0.13, y: 0.14},
          {t: TOUR, x: 0.12, y: 0.3},
          {t: PLUS - 0.15, ...P.addServer},
          {t: PLUS, ...P.addServer, click: true},
          {t: SERVER - 0.15, ...P.serverField},
          {t: SERVER, ...P.serverField, click: true},
          {t: NAME - 0.15, ...P.nameField},
          {t: NAME, ...P.nameField, click: true},
          {t: COLOUR - 0.15, ...P.pink},
          {t: COLOUR, ...P.pink, click: true},
          {t: ICON - 0.15, ...P.cart},
          {t: ICON, ...P.cart, click: true},
          {t: CONNECT - 0.15, ...P.connect},
          {t: CONNECT, ...P.connect, click: true},
          {t: ADDED + 0.2, ...P.connect},
          {t: ARRIVE - 0.1, ...P.clientShop},
          {t: ARRIVE + 0.1, ...P.clientShop, click: true},
          {t: SPLIT - 0.15, ...P.newPane},
          {t: SPLIT, ...P.newPane, click: true},
          {t: THIRD - 0.15, ...P.production},
          {t: THIRD, ...P.production, click: true},
          {t: GRAB - 0.15, ...P.thirdPathBar},
          {t: GRAB, ...P.thirdPathBar, click: true},
          {t: DROP - 0.3, ...P.bottomEdge},
          {t: DROP, ...P.bottomEdge},
          {t: SELECT - 0.15, ...P.releaseNotes},
          {t: SELECT, ...P.releaseNotes, click: true},
          {t: TRANSFER - 0.15, ...P.transfer},
          {t: TRANSFER, ...P.transfer, click: true},
          {t: HOVER, ...P.bottomPane},
          {t: CHOOSE, ...P.bottomPane, click: true},
          {t: CHOOSE + 0.2, ...P.bottomPane},
          {t: CHOOSE + 0.8, ...P.arrived},
        ]}
      />
    </Motion>
    <WindowNotes camera={CAMERA} notes={[
      {from: 0.6, to: PLUS - 0.4, x: 0.175, y: 0.2, side: 'right', text: 'Every server, organised your way'},
      {from: PLUS - 0.3, to: OPEN + 0.5, ...P.addServer, side: 'right', text: 'Add a server'},
      {from: SERVER - 0.1, to: COLOUR - 0.3, x: 0.725, y: 0.33, side: 'right', text: 'Where it is, and its name'},
      {from: COLOUR - 0.2, to: CONNECT - 0.1, x: 0.725, y: 0.62, side: 'right', text: 'A colour and an icon'},
      {from: ARRIVE - 0.2, to: SPLIT - 0.1, x: 0.17, y: P.clientShop.y, side: 'right', text: 'Connected, in your sidebar'},
      {from: GRAB - 0.1, to: SELECT - 0.1, x: 0.34, y: 0.62, side: 'right', text: 'Up to six panes, arranged your way'},
      {from: TRANSFER + 0.1, to: CHOOSE + 1.2, x: 0.19, y: 0.42, side: 'right', text: 'Send files to any pane'},
    ]} />
  </AbsoluteFill>
);
