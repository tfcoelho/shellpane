import React from 'react';
import {AbsoluteFill} from 'remotion';
import {AppWindow, WindowNotes} from '../components/AppWindow';
import {Motion} from '../components/Motion';
import {SHEET_FRAME, sheetOf, state} from '../states';
import {PLACES as P} from '../places';
import {MAX_ZOOM, full} from '../camera';
import {FPS} from '../theme';

// One continuous shot: the organised sidebar, adding a server, where it went. Labels sit beside what to look
// at (no subtitles), and the camera moves the whole window, one straight eased move per change.
const TOUR = 3.0;               // the whole window, the pointer reading down the sidebar
const PLUS = TOUR + 0.9;        // click +
const OPEN = PLUS + 0.2;        // the sheet drops down; the camera leans toward it, once
const SERVER = OPEN + 1.4;      // click the Server field, then two typing steps
const NAME = SERVER + 1.5;      // click Name, then two typing steps
const COLOURS = NAME + 2.0;     // purple, then pink (blue was the default)
const STEP = 0.8;
const ICONS = COLOURS + 2 * STEP + 0.4;   // flask, then the cart (the server icon was the default)
const CONNECT = ICONS + 2 * STEP + 0.6;
const CLOSE = CONNECT + 0.2;    // the sheet goes up
const ADDED = CLOSE + 0.3;      // in the sidebar, open on the right
const ARRIVE = ADDED + 1.0;     // the pointer reaches the new row; the camera shows the whole window
export const APP_SECONDS = ARRIVE + 2.2;
export const APP_FRAMES = Math.round(APP_SECONDS * FPS);

const form = {x: 0.56, y: 0.42, zoom: 1.1};
const appearance = {x: 0.56, y: 0.62, zoom: MAX_ZOOM};
const connect = {x: 0.6, y: 0.76, zoom: 1.12};
const CAMERA = [
  {t: 0, ...full},
  {t: OPEN, ...full},
  {t: OPEN + 1.2, ...form},
  {t: NAME + 1.0, ...form},
  {t: COLOURS - 0.2, ...appearance},
  {t: ICONS + 2 * STEP, ...appearance},
  {t: CONNECT - 0.15, ...connect},
  {t: ADDED + 0.1, ...connect},
  {t: ARRIVE, ...full},              // back to the whole window: the new row and the server it opened
];
const picks = (start, name, from) => [0, 1].map((i) => ({...sheetOf(state(name, from + i)), at: start + i * STEP + 0.1}));
const clicks = (start, places) => places.flatMap((p, i) => [
  {t: start + i * STEP - 0.15, ...p},
  {t: start + i * STEP, ...p, click: true},
]);

export const AppScene = () => (
  <AbsoluteFill>
    <Motion>
      <AppWindow
        intro
        exit={{duration: APP_FRAMES, frames: 16}}
        states={[{...state('overview'), at: 0}, {...state('added'), at: ADDED}]}
        sheet={{frame: SHEET_FRAME, from: OPEN, to: CLOSE, states: [
          {...sheetOf(state('form-empty')), at: 0},
          {...sheetOf(state('form-host', 0)), at: SERVER + 0.35},
          {...sheetOf(state('form-host', 1)), at: SERVER + 0.75},
          {...sheetOf(state('form-name', 0)), at: NAME + 0.35},
          {...sheetOf(state('form-name', 1)), at: NAME + 0.75},
          ...picks(COLOURS, 'form-colour', 1),   // captured: green, purple, pink; shown: purple, pink
          ...picks(ICONS, 'form-icon', 1),       // captured: globe, flask, cart; shown: flask, cart
        ]}}
        camera={CAMERA}
        cursor={[
          {t: 0.9, x: 0.34, y: 0.22},
          {t: 2.0, x: 0.13, y: 0.14},
          {t: TOUR, x: 0.12, y: 0.3},
          {t: PLUS - 0.15, ...P.addServer},
          {t: PLUS, ...P.addServer, click: true},
          {t: SERVER - 0.15, ...P.serverField},
          {t: SERVER, ...P.serverField, click: true},
          {t: NAME - 0.15, ...P.nameField},
          {t: NAME, ...P.nameField, click: true},
          ...clicks(COLOURS, [P.purple, P.pink]),
          ...clicks(ICONS, [P.flask, P.cart]),
          {t: CONNECT - 0.15, ...P.connect},
          {t: CONNECT, ...P.connect, click: true},
          {t: ADDED + 0.2, ...P.connect},
          {t: ARRIVE - 0.1, ...P.clientShop},
          {t: ARRIVE + 0.1, ...P.clientShop, click: true},
        ]}
      />
    </Motion>
    <WindowNotes camera={CAMERA} notes={[
      {from: 0.8, to: PLUS - 0.5, x: 0.175, y: 0.2, side: 'right', text: 'Every server, organised your way'},
      {from: PLUS - 0.4, to: OPEN + 0.5, ...P.addServer, side: 'right', text: 'Add a server'},
      {from: SERVER - 0.1, to: COLOURS - 0.6, x: 0.725, y: 0.33, side: 'right', text: 'Where it is, and its name'},
      {from: COLOURS - 0.4, to: CONNECT - 0.3, x: 0.725, y: 0.62, side: 'right', text: 'A colour and an icon'},
      {from: ARRIVE - 0.2, to: APP_SECONDS - 0.2, x: 0.17, y: P.clientShop.y, side: 'right', text: 'Connected, in your sidebar'},
    ]} />
  </AbsoluteFill>
);
