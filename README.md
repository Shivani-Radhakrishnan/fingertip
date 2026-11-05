# Fingertip

**Fingertip helps blind people use touchscreens and button panels on things like microwaves, washing machines and kiosks.** You prop your phone so it faces the panel and say what you want, like "heat for 2 minutes". It reads the panel, plans which buttons to press, guides your finger to each one, and checks that each press worked.

Built for the Meta Global AI Developer Hackathon (Indie track), Oct 27 – Nov 4, 2026. Everything in this repo was written during the hackathon.

## The problem

Flat touch panels have no buttons you can feel. In Vision Australia's 2025 survey of 627 blind and low-vision people, 82% named flat or unlabelled buttons as a problem, and 67% named touchscreens with no tactile or voice option. Today people stick bumps on their appliances (which needs a sighted helper), memorize where buttons are, or call a sighted person on video.

Other tools already help part of the way. Gemini Live, Meta AI and Apple's Point and Speak can tell you what is on a panel or what is under your finger. None of them guides your finger to the button you need, plans the presses for your goal, or checks that each press worked. Fingertip tries to do that whole loop on the phone.

## How it works

```
iPhone (propped up)                     Backend (FastAPI)                    Meta models
camera photo  ───────────────────────►  Reader: every control, incl. icons ─► Muse Spark 1.3
                                        button center points (0-1000)
                                        Segmenter: exact outline per button ─► SAM 3.1 (point prompts)
voice (streamed) ────────────────────►  hands-free goal, tuned to labels ───► Muse Voice Transcribe
                                        Planner: goal -> ordered presses ───► Muse Spark 1.3
live camera ─► Guide (on the phone): ARKit pins buttons to the panel,
               Apple Vision tracks the fingertip,
               spoken words for big moves -> faster ticks -> "On it. Press."
photo after a press ─────────────────►  Critic: before vs after -> ok / retry / wrong ─► Muse Spark Open (Baseten),
                                        wrong -> re-plan                                  or Muse Spark 1.3 fallback
```

**Two Meta models are chained.** Muse Spark gives each button's center point, and SAM 3.1 turns that point into an exact outline. This works for icon-only buttons too, which a text prompt can't reliably target.

**Every model returns strict JSON**, so each agent's output feeds the next step directly.

**The live loop runs on the phone.** The Meta API works on uploaded images, not live video. So fingertip tracking (Apple Vision) and anchoring (ARKit) run on the phone, with instant feedback and no cost per frame. ARKit tracks the whole room, so the hand covering a glossy panel doesn't break it. If ARKit can't find the surface, the app falls back to the photo positions, which stay valid while the phone is on a stand.

**Guidance follows what studies with blind users found works:** a few words for big moves, ticks and vibration that speed up near the target, then a clear press cue. The app also:
- speaks the plan first
- accepts "repeat", "skip" and "stop"
- asks you to move your hand out of the way before taking a photo
- speaks through VoiceOver when VoiceOver is on, so two voices never overlap

**Safety.** The planner is told never to guess what an unreadable button does. Instead it asks for a clearer view. The Reader says when the framing is bad ("move the phone closer") rather than inventing buttons.

**Device memory.** A panel seen before from the same spot is recognised instantly, at no cost.

## Results so far

The test ran on 6 real appliance photos from Wikimedia Commons (credits in `tests/panels/CREDITS.md`): microwaves with Korean and Dutch-style panels, two washing machines (one with Chinese labels), and a dishwasher touch strip. Five of them were labelled by hand. Run it yourself with `python tests/eval.py`.

| Metric | Result |
| --- | --- |
| Labelled controls found by the Reader | **20 / 26 (77%)** |
| Icon-only controls found | **6 / 8 (75%)** |
| Buttons with an exact SAM 3.1 outline | 26 of 33 detected buttons |
| Panels where the Reader correctly flagged bad framing | the blurry, cut-off store photo (`microwave3`) |
| Time to read a panel (Reader + SAM) | ~18.5 s average |
| Cost to read a panel | ~$0.011 average |

What it missed: the Korean microwave's start, stop and power buttons (it found 4 of 7), a door-release button, a power icon on an angled, out-of-focus dishwasher strip, and a washer's prewash icon.

**Tested on a real microwave (iPhone 15):** the app scans the panel, hears a spoken goal ("heat for 2 minutes"), plans the presses and starts guiding to the first button. Reading a panel takes about 10 s in Muse Spark's fastest mode.

**Honest status, not done yet:**
- **Live motion-following is off.** Pinning buttons in 3D with ARKit was unreliable on a glossy black panel in testing: outlines drifted. For now the app uses the photo positions, which are exact while the phone is held still or propped up.
- **No blind testers yet.** The press checker has only been tested through the API, not across a full guided run.
- These are the next things to fix.

## Cost and privacy

- Every model call is logged with its tokens, cost and latency (`backend/calls.jsonl`). The backend refuses all calls past a hard limit (default $120), because Meta's billing page can only send email alerts.
- Images are resized to 1024px. Fixed instructions go first so prompt caching can reuse them.
- We use Meta's Standard tier, not the cheaper Contributor tier, because the Contributor tier trains on inputs, and these photos come from people's homes.
- We avoid payment card terminals on purpose (PINs).

## Run it

Backend:

```
python3 -m venv .venv && .venv/bin/pip install -r backend/requirements.txt
cp backend/.env.example backend/.env     # add META_API_KEY (and optionally BASETEN_API_KEY)
cd backend && ../.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
```

Quick check without a phone: `cd backend && ../.venv/bin/python smoke.py ../tests/panels/washer.jpg "start a wash"`

iPhone app (iOS 17+, any iPhone; no LiDAR needed):

```
brew install xcodegen && cd ios && xcodegen generate && open Fingertip.xcodeproj
```

Set your signing team, run it on a device, and enter the backend address (your Mac's IP and port 8000) under the gear icon.

## Built with

- **Muse Spark 1.3:** reading the panel (with grounding), planning, and the critic fallback
- **SAM 3.1:** button outlines from point prompts
- **Muse Voice Transcribe:** hands-free goal, with endpointing and keywords
- **Built with Muse Spark Open:** the critic, through Baseten, when configured
- Apple ARKit, Vision, AVFoundation, Core Haptics; FastAPI

## Credits

Test photos come from Wikimedia Commons under CC BY / CC BY-SA licenses; see `tests/panels/CREDITS.md`. Research that shaped the design: VizLens (Guo et al., UIST 2016), StateLens (UIST 2019), NaviSense (ASSETS 2025), HandSight (TACCESS 2016), Vision Australia appliance survey (2025).
