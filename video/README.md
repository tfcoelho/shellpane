# Shellpane launch video

Rendered with [Remotion](https://www.remotion.dev) at 60 fps from the real app. Nothing in the window is mocked:
`scripts/video-footage.sh` plays the story in Shellpane against a throwaway server (the organised sidebar,
adding a server, a Finder tag, a favourite folder) and saves the window after every step at 3×
(`public/states/`), plus the form sheet and where it sits. Shellpane's own changes are instant, so all the motion (camera,
transitions, motion blur) comes from Remotion between those real states: smoother and sharper than filming
the screen, and no Screen Recording permission.

```sh
../scripts/video-footage.sh     # capture public/states/ (neutral sidebar, user "deploy")
npm install                     # once
npm run studio                  # preview and scrub in the browser
npm run render                  # out/shellpane-launch.mp4, 1920×1080, 60 fps
```

Music: put a licensed track in `public/` and render with
`npx remotion render src/index.js Launch out/shellpane-launch.mp4 --props='{"music":"music.mp3"}'`.

Remotion is free for individuals and companies of up to 3 people; check its licence terms before commercial
use by a larger company. The font is Inter (SIL Open Font License), loaded from Google Fonts at render time.

## What it says

One message: **all your servers, organised your way, and adding one takes seconds.** The cut shows the
organised sidebar, then adding a server with a colour and an icon, then where it went. Other features
(F5, filter, tags, favourite folders) belong on the website; in a 25-second video they dilute the point.

## How the camera behaves (`src/camera.js`)

The camera moves the whole window, frame and shadow included, like a camera over a desk; it never crops
inside the frame. The full window is the default framing. A lean-in is gentle (at most 1.3×) and only for the
moment worth seeing up close. Each change is one straight, eased move (scale and position interpolate
together), holding still in between; a window bigger than the frame never leaves more than 60 px of
background at an edge.

Scenes don't crossfade: each leaves before the next arrives. Labels sit beside what to look at instead of
subtitles at the bottom. Text rises with opacity only, no blur.

## On a web page

The edges are one flat colour, `#0c0d0f` (`BG` in `src/theme.js`); the glow fades out well inside the frame.
Put the video on a section with that background and it blends in. A fine grain inside the glow (about ±2 levels,
new every frame, like film grain) dithers the gradient so 8-bit video doesn't band; it's masked away from the
edges. Measured on a rendered frame: identical-colour runs across the glow went from a median of 31–39 px
(visible bands) to 4–5 px. `npm run render` encodes at CRF 16 with the slow preset so the grain survives.

## Structure

Following Remotion's own agent guidance (remotion-dev/skills): one file per scene, each also
registered on its own under "Scenes" so it can be previewed and timed alone, joined with `<TransitionSeries>`.

- `src/components/Logo.jsx`: the icon drawn in the same grid as `design/icon/make_icon.py`, with its reveal
- `src/components/AppWindow.jsx`: the floating window, the camera, and the cuts between captured states
- `src/components/Motion.jsx`: motion blur on camera moves (`MOTION_BLUR` in `src/theme.js` turns it off)
- `src/components/Cursor.jsx`: the pointer that glides and clicks, in window coordinates
- `src/places.js`: where things are in the captured window (pointer and camera targets)
- `src/scenes/`: Logo, Headline, TheApp (one continuous shot: sidebar, adding a server, where it went), Yours, End

Recording mode keeps your Mac out of it: a neutral sidebar (`SHELLPANE_DEMO_SIDEBAR`), a stand-in user name
(`SHELLPANE_DISPLAY_USER`), demo Finder tags on demo files (`SHELLPANE_DEMO_TAGS`, found by walking
`SHELLPANE_DEMO_TAG_ROOT` since Spotlight skips temporary folders), and `shop.example.com` routed to the demo
server by a pattern in the demo ssh_config.
- `src/Launch.jsx`: the cut
