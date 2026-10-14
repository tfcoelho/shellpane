// The app's own states, captured at 3× by scripts/video-footage.sh (public/states/states.json, in order).
import data from '../public/states/states.json';

const all = data.states;

/** The `i`-th state with this name ("form-host" appears once per typing step). */
export const state = (name, i = 0) => {
  const s = all.filter((x) => x.name === name)[i];
  if (!s) throw new Error(`No "${name}" #${i} state: re-run scripts/video-footage.sh`);
  return s;
};
/** A state's sheet image, as a state of its own. */
export const sheetOf = (s) => ({file: s.sheet});
/** Where the form sheet sits on the window: [x, y, w, h] fractions. */
export const SHEET_FRAME = all.find((s) => s.sheetFrame)?.sheetFrame ?? [0.28, 0.07, 0.44, 0.89];
