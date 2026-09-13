# halogen-flash-flake

NixOS deployment module for [peonist-ai/halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) — the ROCm inference server for Qwen3.8-Flash-Next on AMD Strix Halo, run as a managed Podman container via systemd.

Design goals (deliberately conservative):

- **One image tag, always** — engine and API never drift apart (an older API in front of a newer engine silently mis-routes requests; upstream issue #26).
- **The container never dials out.** Weights come from `hf download` on the host (`ExecStartPre`, idempotent + resumable) or from a pre-provisioned directory; the models volume is mounted read-only.
- **Upstream's container contract, verbatim** — `/dev/kfd` + `/dev/dri`, `--group-add keep-groups`, `--ipc=host`, `--ulimit memlock=-1:-1`. Keep in sync with their `docker-compose.yml` when they change it.

## Usage

Add the flake as an input to your NixOS host config:

```nix
# flake.nix
inputs.halogen-flash = {
  url = "github:javierarrieta/halogen-flash-flake"; # or path:../halogen-flash-flake
  inputs.nixpkgs.follows = "nixpkgs";
};

# host configuration.nix (specialArgs must expose `halogen-flash`)
imports = [ halogen-flash.nixosModules.default ];

services.halogenFlash = {
  enable = true;
  mode = "all";                          # or "split" — see below
  modelsDir = "/opt/llm/halogen/models"; # ~130 GiB headroom on a big volume
  download.enable = true;                # hf download as ExecStartPre (idempotent)
  image = "ghcr.io/peonist-ai/halogen-flash-server:0.6.3";
};
```

Then `nixos-rebuild switch`. The **first start takes hours** (~118 GiB weight transfer, resumable); the OpenAI-compatible endpoint is at `http://<host>:8731/v1`, `/health` reports both versions and supported features.

### Modes

| mode | shape | restart cost |
|---|---|---|
| `all` (default) | one container, engine on internal loopback + published API port (upstream quickstart) | weight reload (~minutes) |
| `split` | two systemd units on host networking: `halogen-flash-engine` (loopback only, never published) and `halogen-flash-api` | API restarts are free; the API unit waits for the engine service and crash-loops harmlessly until it is ready |

### Options (`services.halogenFlash.*`)

- `image` — full reference, used as-is (bump + `podman pull` to upgrade).
- `port` / `enginePort` — 8731 / 8730.
- `modelsDir` — where the checkpoint, quality sidecar and `tokenizer/` live.
- `download.{enable,repo}` — host-side weight fetch before each start (default repo `peonist-ai/halogen-qwen3.8-flash-next`).
- `enableVision` — sets `HALOGEN_VISION_TOWER=1` (vision sidecar must be in `modelsDir`).
- `environment` — extra `HALOGEN_*` overrides. Do **not** mirror shipped defaults here: when the image changes, a stale override silently wins (upstream's own words on their compose file). See upstream `docs/FLAGS.md`.
- `extraRunArgs` — raw `podman run` pass-through, appended last.

### Operations

```bash
systemctl status halogen-flash            # or -engine / -api in split mode
journalctl -u halogen-flash -f            # weight load takes minutes on first boot
curl http://localhost:8731/health         # engine + api versions, feature list
podman ps                                 # container is `--rm`; gone after stop
```

Caveats:

- **GTT memory is host-wide.** On Strix Halo the iGPU and CPU share one pool (~128 GiB). This server needs ~115 GiB of weights resident, so it is mutually exclusive with anything else living in GTT (e.g. a multi-model `llama-cpp-server` preset) — run one or the other at a time.
- There is no systemd-level health gating; if the engine wedges (`podman ps`, `/health`), restart the unit. Upstream ships an in-container `halogen-healthcheck` that only their compose topology uses.
- Podman storage here is the root system store — unrelated to any user/rootless podman setup on the same host.
