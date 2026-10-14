// Where things are in the captured window, as fractions of its 1180×720 points (read off the captures).
// The pointer and the camera aim here. After "Client shop" is added, the sidebar below it moves down a row.
const pt = (x, y) => ({x: x / 1180, y: y / 720});
const ROW = 28;

export const PLACES = {
  addServer: pt(188, 62),
  production: pt(96, 85),
  // In the form sheet (sheet at 330, 52 on the window).
  serverField: pt(330 + 432, 52 + 210),
  nameField: pt(330 + 450, 52 + 173),
  green: pt(330 + 350, 52 + 376),
  purple: pt(330 + 446, 52 + 376),
  pink: pt(330 + 478, 52 + 376),
  globe: pt(330 + 239, 52 + 429),
  flask: pt(330 + 281, 52 + 468),
  cart: pt(330 + 239, 52 + 468),
  connect: pt(330 + 469, 52 + 613),
  // After adding.
  clientShop: pt(110, 197),
  clientTag: pt(62, 489 + ROW),
  assetsFolder: pt(68, 257 + ROW),
  // The tag view's two rows, and the right pane.
  firstRow: pt(280, 122),
  secondRow: pt(280, 146),
  rightPane: pt(860, 200),
};
