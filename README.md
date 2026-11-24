[![ci](https://github.com/VonBorstel-J/tide/actions/workflows/ci.yml/badge.svg)](https://github.com/VonBorstel-J/tide/actions/workflows/ci.yml)

# Tide

I run coding jobs on a Windows PC and review them from my phone. Tide gives each change its own branch, runs the tests, and lets me see which jobs need a decision. A worker can hang, hit its memory limit, or stop halfway through a change. The supervisor keeps enough state on disk to pick up the queue after a restart.

## Watch a job recover

On Windows with PowerShell 7, run this from the repository root.

```powershell
pwsh -File kitchen/demo.ps1 -Open
```

The demo starts ten simulated workers in a temporary folder. Watch the one that fails on its first try and the one that keeps failing. Halfway through, the demo restarts the supervisor. The deployment step waits for approval, which the demo supplies. At the end you can inspect the status page and the event log. [Demo script](kitchen/demo.ps1) · [Supervisor tests](tests/Test-KitchenSupervisor.ps1)

In daily use I make that decision from the Board, the phone interface. I can read what a job wants to change, approve it, or stop it. The Board reaches the PC over Tailscale. The Yard is the job runner on the PC. [Phone interface](pass-app/README.md) · [Job runner](kitchen/README.md)

## Running Tide

The Windows setup uses one account. Paths default to `%USERPROFILE%` and private settings live under `%LOCALAPPDATA%\brain-kitchen`. The public repository starts with the October 24, 2026 snapshot. [Build and contribution notes](kitchen/BUILDING.md) · [License](LICENSE) · [Bundled font license](pass-app/public/OFL.txt) · [Report a security issue](SECURITY.md)

**Run a test suite.** `pwsh -NoProfile -File scripts/run-bounded.ps1 -Script tests/Test-PassApp.ps1 -TimeoutSeconds 1200` (every suite in `tests/` runs the same way).

## Limits

Tide runs on a single Windows PC. The demo exercises the supervisor with simulated workers. A passing test tells me what the tests covered. I still review the change before I merge it. For the scripts that maintain notes between jobs, their limits, and the history of individual tools, see the [operating notes](docs/OPERATING-NOTES.md).
