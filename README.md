# Fingertip

Fingertip helps blind people use touch panels on things like microwaves, washing machines and kiosks.

You point your phone at the panel and say what you want, like "heat for 2 minutes". The app reads the panel, works out which buttons to press, guides your finger to each one, and then checks if the press worked.

I built this for the Meta Global AI Developer Hackathon (Indie track), Oct 27 to Nov 4, 2026. All the code here was written during the hackathon.

## Why

Flat touch panels have no buttons you can feel. In Vision Australia's 2025 survey (627 blind and low-vision people), 82% said flat or unlabelled buttons are a problem and 67% said touchscreens with no tactile or voice option are a problem. Right now people put stick-on bumps on their appliances, memorize where the buttons are, or video call a sighted person.

Some apps already help part of the way. Gemini Live, Meta AI and Apple's Point and Speak can tell you what's on a panel or what's under your finger. But they don't guide your finger to the button you need, plan the presses for what you want to do, or check that each press worked. That's the part I wanted to build.

I worked on indoor navigation for blind users before this ([NavAssist](https://github.com/Shivani-Radhakrishnan/NavAssist)), and appliances kept coming up as a problem.

## How it works

1. **Read the panel.** The phone takes a photo. Muse Spark lists every control on it, including icon-only ones (like a snowflake for defrost), with the center point of each one. It also says if the photo is bad ("move the phone closer").
2. **Outline the buttons.** Each center point goes to SAM 3.1 as a point prompt, and SAM gives back the exact outline of that button.
3. **Hear what you want.** Muse Voice Transcribe listens without needing a button press. It gets the panel's button names as keywords, so it hears "Defrost" correctly.
4. **Plan.** Muse Spark turns the goal into button presses in order and says the plan out loud ("2 presses: 2 min, then Start"). If a button it needs is unreadable, it says so instead of guessing.
5. **Guide your finger.** This part runs on the phone. Apple Vision tracks your fingertip in the camera. The app says short words for big moves ("left", "up"), then ticks and vibrates faster as you get close, then says "On it. Press." The buttons shift with the picture if your hand moves a bit.
6. **Check.** After a press it compares a before and after photo of the panel (did the display change to 2:00?). If the press missed it tells you to press again. If the wrong thing happened it makes a new plan. This runs on Muse Spark Open through Baseten when a key is set, otherwise on Muse Spark.

Every model call returns JSON, so each step can use the last one's output directly.

Some choices I made from reading accessibility research (VizLens, StateLens, NaviSense, HandSight):

- The phone should be propped up or held still, not held in one hand while pressing with the other.
- Words for coarse directions, ticks for the last few centimeters.
- Keep speech short, and don't talk over VoiceOver.
- Never tell the user to press something you're not sure about.

There are no on-screen buttons. A blind user can't find buttons on a phone screen any more than on a microwave. So the app scans by itself when it opens, and you tap anywhere to scan or hold anywhere to talk.

## Results

I tested the reading step on 6 appliance photos from Wikimedia Commons (credits in `tests/panels/CREDITS.md`). They're two microwaves (one with Korean labels), two washing machines (one with Chinese labels), a dishwasher touch strip, and a blurry store photo. I labelled 5 of them by hand. Run `python tests/eval.py` to repeat it.

| | Result |
| --- | --- |
| Controls found | 20 out of 26 (77%) |
| Icon-only controls found | 6 out of 8 (75%) |
| Time to read a panel | about 10 to 18 s |
| Cost to read a panel | about $0.01 |
| Blurry photo | correctly said "move the phone closer" instead of guessing |

What it missed: three buttons on the Korean microwave, a door-release button, a power icon on the out-of-focus dishwasher, and a prewash icon.

I also ran it on my own microwave with an iPhone 15. It scanned the panel, heard "heat for 2 minutes", made the plan and started guiding me to the first button.

## What doesn't work yet

- **Following the phone when it moves.** I tried ARKit first, but on my glossy black microwave panel the boxes drifted a lot. The current version shifts the boxes using image matching instead. It's better, but it still needs work.
- **Fingertip tracking** isn't reliable over a dark, reflective panel.
- **Testing with blind users.** I haven't done this yet and it's the next thing I want to do.
- The full press, check, re-plan loop hasn't been tested end to end on a real appliance.

## Cost and privacy

- Every API call is logged with its tokens, cost and time (`backend/calls.jsonl`). The backend also stops making calls after $120, because Meta's billing page can only send an email warning.
- I use the normal Meta API tier, not the cheaper Contributor tier, because that one uses your inputs for training. These photos are taken inside people's homes.
- It doesn't support card payment terminals, on purpose (PINs).

## Running it

Backend:

```
python3 -m venv .venv && .venv/bin/pip install -r backend/requirements.txt
cp backend/.env.example backend/.env    # add META_API_KEY, and BASETEN_API_KEY if you have one
cd backend && ../.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
```

To try it without a phone:

```
cd backend && ../.venv/bin/python smoke.py ../tests/panels/washer.jpg "start a wash"
```

iPhone app (iOS 17+, works without LiDAR):

```
brew install xcodegen
cd ios && xcodegen generate && open Fingertip.xcodeproj
```

Set your signing team, run it on your phone, and put your Mac's address (port 8000) in the settings under the gear icon.

## Built with

- Muse Spark 1.3 (reading the panel, planning, checking)
- SAM 3.1 (button outlines from point prompts)
- Muse Voice Transcribe (hands-free voice)
- Built with Muse Spark Open (the press checker, through Baseten)
- Apple ARKit, Vision, AVFoundation and Core Haptics, plus FastAPI

## License

MIT. Test photos are from Wikimedia Commons under CC BY and CC BY-SA licenses; see `tests/panels/CREDITS.md`.
