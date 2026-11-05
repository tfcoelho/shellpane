// Where things are in the captured window, as fractions of its 1180×720 points (read off the captures).
// The pointer and the camera aim here.
const pt = (x, y) => ({x: x / 1180, y: y / 720});

export const PLACES = {
  addServer: pt(188, 62),
  production: pt(96, 85),
  // In the form sheet (sheet at 330, 52 on the window).
  serverField: pt(330 + 432, 52 + 210),
  nameField: pt(330 + 450, 52 + 173),
  pink: pt(330 + 478, 52 + 376),
  cart: pt(330 + 239, 52 + 468),
  connect: pt(330 + 469, 52 + 613),
  // After adding.
  clientShop: pt(110, 197),
  // Arranging panes: the toolbar, the third pane's path bar, the bottom edge.
  newPane: pt(872, 25),
  transfer: pt(913, 25),
  thirdPathBar: pt(1045, 67),
  bottomEdge: pt(690, 702),
  // Two on top, one below: a file on the Mac, the bottom pane in the picker, and where the file lands.
  releaseNotes: pt(300, 314),
  bottomPane: pt(700, 560),
  arrived: pt(330, 647),
};
