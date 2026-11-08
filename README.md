NightShift

A night-shift console that catches failing equipment, counts down to shutdown, and finds the cheapest way to keep the field running, with a Nemotron agent doing the triage and Ray-Ban Meta glasses bringing it to the operator hands-free.

Built at HackUTD 2026 for the EOG Resources "Beat the Shutdown" challenge and the NVIDIA Nemotron track.

The problem

At night, one operator watches a whole salt water network: wells fill tanks, pumps empty them into pipelines, and pipelines carry the water to a disposal site. When a pump fails, its tank starts filling. If it hits the shutdown limit, the wells shut in and stop earning money until the repair is done.

The operator has to work out what's failing, how long until the tank trips, and whether to send trucks, shut in some wells early, or let it shut down, often with several failures fighting over the same few trucks. Meanwhile, anything they see on site and anything that happened on the last shift is easy to lose at handover.

What NightShift does

1. Finds what's failing (from the sensor data only)

Detects the three problems in the telemetry: pump failure, pump wearing out, and pipeline leak
Each alert comes with when it started, whether it's still going, a confidence level, and plain-English evidence

2. Predicts the time before it worsens

For every pump failure, a countdown to the tank's shutdown limit, fit over the whole fault period so noisy readings don't throw it off
Shown as a range (p10 / p50 / p90)

3. Finds the lowest-cost path to keep running

An optimizer compares every option: trucks and trips, shutting in different wells at different times, mixes of both, or doing nothing
Follows every rule in the spec: truck response and cycle times, fleet size, repair horizon, trips arriving before the tank trips
Plans all failures in a system together, since they share the same trucks
Keeps the tank strictly below the shutdown limit with a small safety margin

4. A Nemotron agent runs the triage on its own

Starts automatically when a dataset loads, so nobody has to type a prompt
Plans and executes the workflow with tool calls: load_dataset → detect_events → forecast_shutdown → optimize_plan → get_fleet_status → get_weather → save_alerts → export_events
Never invents a number. Every figure comes from a tool, and the agent explains and writes up the result
The Agent trace page shows every step, tool call and result

5. Ray-Ban Meta glasses in the field

Alerts and the cheapest plan are spoken to the operator through the glasses: "S5 Facility C pump failed. Shutdown in about 2 hours. Cheapest fix: one truck, 905 dollars."
The glasses camera streams to the iPhone, and frames are checked by Nemotron for visible leaks, smoke or damage
The operator confirms or dismisses each flag by voice
Flags, photos and notes are saved on the iPhone and uploaded at the end of the shift

6. Handover

A plain-English shift handoff the next operator can read in 30 seconds
Next-shift priorities, most important first, with the reason for each
Export to events.json in EOG's format


Running it

Requirements: Python 3, Node.js, an NVIDIA API key from build.nvidia.com

bash
export NVIDIA_API_KEY=nvapi-...
./start.sh


Pick a dataset from the Dataset switcher (full week, snapshots, mock test, or test/)
Without an API key, the agent runs an offline script and says so on the Agent trace page

Score against the answer keys (practice folders only):

bash
backend/.venv/bin/python dev/score.py          # quick
backend/.venv/bin/python dev/score.py --brute  # also re-checks the optimizer exhaustively

iPhone + glasses: see the ios/ folder. The phone and the laptop running the backend need to be on the same network.
