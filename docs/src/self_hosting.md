# Running your own Nominatim server (for bulk geocoding)

The public server at `nominatim.openstreetmap.org` allows **one request per
second**, and jobs that run longer than a day are cut to **four requests per
minute** ([usage policy](https://operations.osmfoundation.org/policies/nominatim/)).
That is fine for a few thousand addresses and useless for a million.

Your own server has no limits. This guide sets one up for the **United States**
on a Windows 11 PC using **WSL2** (Linux inside Windows), without Docker.

> **Tested:** Path A was followed end to end in September 2026 on a laptop with
> an Intel Core Ultra 9 185H, 64 GB RAM and a 1 TB NVMe SSD (WSL 2.7.14,
> Ubuntu 24.04, PostgreSQL 16, osm2pgsql 1.11, Nominatim 5.3.2). All times and
> sizes marked *measured* come from that run. Path B (Docker) and the sections
> marked *untested* were **not** tried.

The steps work for other regions: swap the download link for another
[Geofabrik extract](https://download.geofabrik.de/).

## How to read the commands

- **Each gray box is one step.** Copy the whole box, paste it into the terminal,
  press Enter, and **wait until the prompt comes back** (the line ending in `$`)
  before doing the next box.
- The heading above each box says where it runs: **PowerShell** (Windows) or
  **Ubuntu** (the Linux terminal).
- Where you should check something, the text says what the output should look like.
- Boxes that start `tmux` or a long-running program are always on their own:
  anything pasted after them would be swallowed.

---

## 1. What you need

| | Used in the tested run |
|---|---|
| Windows | Windows 11 |
| RAM | 64 GB (48 GB given to WSL) |
| CPU | 22 logical cores (10 given to WSL) |
| Disk | NVMe SSD, **≥ 250 GB free** (see below) |
| Time | ~30 min of setup, then **~15.5 hours** of import that runs on its own |

A spinning hard disk would take days or weeks. 16 GB of RAM can work, but expect
a much slower import.

### Disk space (measured, US extract)

| Item | Size |
|---|---|
| US OpenStreetMap extract (`us-latest.osm.pbf`) | 12 GB |
| Flatnode file (node locations, deleted automatically after loading) | **113 GB** |
| Database while loading | 65 GB |
| **Peak extra space used on `C:`** | **~200 GB** |
| Final database | **90 GB** |
| Space still taken on `C:` after the import | **~230 GB** (see note) |

**The WSL virtual disk does not shrink.** Linux reported only 106 GB in use after
the import, but the virtual disk file on `C:` stays at its largest size. Plan
for that space to stay taken.

### Why a 12 GB download becomes a 90 GB database

The `.osm.pbf` file is heavily compressed. Nominatim unpacks it into PostgreSQL
and adds real geometries for every road, building and boundary, search indexes,
and a precomputed address chain for every place (house → street → city → county
→ state).

### Where the data must *not* go

- **Not in OneDrive** (or Dropbox, Google Drive, …).
- **Not on `/mnt/c/...` from inside Ubuntu.** Windows folders seen from Linux are
  very slow. Everything in this guide lives in your Linux home folder (`~`).

### Decisions made in this guide

- **Whole US extract.** It includes Alaska, Hawaii and territories; they are small.
- **No US TIGER data.** TIGER adds address *ranges* along streets, so its results
  are interpolated estimates (like the Census geocoder). Without it, every
  house-level result is a real address point from OpenStreetMap. Where
  OpenStreetMap has no house numbers you get a street-level match instead.
- **`extratags` import style**: keeps almost every OpenStreetMap tag (website,
  phone, opening hours, …).
- **No updates** (`--no-updates`): a frozen snapshot. Smaller, and results stay
  reproducible. To get newer data, re-import.

---

## 2. Before you start: stop Windows from interrupting

The import runs for about 15.5 hours. In the tested run it was **interrupted twice**:
once by an automatic Windows Update restart at 1 AM, once by a forced power-off.

1. **Pause Windows Update:** Settings → Windows Update → **Pause updates** →
   *Pause for 5 weeks*. Check the date it shows; an old pause may have expired.
2. **Never sleep when plugged in:** Settings → System → Power & battery → Screen,
   sleep & hibernate timeouts → *When plugged in, put my device to sleep after*:
   **Never**.
3. **Plug in the laptop, and don't carry it around** while the import runs (it
   works hard and gets hot; hibernating may not work).
4. If you must stop, stop cleanly (see *If the import stops* (in Path A)).

---

## Path A: WSL2 without Docker

### A1. Tell WSL how much memory and CPU it may use

Create the file `C:\Users\<you>\.wslconfig` in Notepad with:

```ini
[wsl2]
# Leave ~12-16 GB for Windows. On a 64 GB machine: 48GB. On 32 GB: 24GB.
memory=48GB
# Leave some cores for Windows.
processors=10
swap=16GB
```

Do **not** add `sparseVhd=true`: WSL 2.7 disables sparse virtual disks because of
a data-corruption risk. During installation you may see *"Sparse VHD support is
currently disabled"*; ignore it and don't force it.

### A2. Install WSL and Ubuntu 24.04

**PowerShell** (run as administrator):

```powershell
wsl --install -d Ubuntu-24.04
```

Restart Windows only if it asks (on the tested machine it did not). Ubuntu opens
and asks for a **Linux user name and password**; they don't have to match
Windows. You end up at a prompt like `yourname@PC:/mnt/c/Users/yourname$`.

**PowerShell**, check it runs as WSL 2 (the `VERSION` column must say `2`):

```powershell
wsl --list --verbose
```

### A3. Go to your Linux home folder

Ubuntu starts in the Windows folder (`/mnt/c/...`), which is slow. **Ubuntu:**

```bash
cd ~
```

The prompt now ends in `:~$`. Opening Ubuntu later starts in `~` too, unless you
open it from a Windows folder.

### A4. Check that systemd is on

**Ubuntu:**

```bash
cat /etc/wsl.conf
```

You should see `systemd=true` under `[boot]` (Ubuntu 24.04 sets this by default).
If it is missing, run this, then `wsl --shutdown` in PowerShell and reopen Ubuntu:

```bash
printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
```

### A5. Install PostgreSQL, PostGIS, osm2pgsql and tools

**Ubuntu** (asks for your Linux password; takes a few minutes):

```bash
sudo apt-get update && sudo apt-get install -y osm2pgsql postgresql-postgis postgresql-postgis-scripts pkg-config libicu-dev python3-venv python3-dev build-essential wget tmux
```

**Ubuntu**, check the versions:

```bash
psql --version && osm2pgsql --version
```

Expected: PostgreSQL **16.x** and osm2pgsql **1.11.x** (Nominatim needs ≥ 12 and
≥ 1.8). The paths below use `16`; adjust if yours differs.

### A6. Tune PostgreSQL for the import

**Ubuntu** (paste the whole box; it writes one settings file):

```bash
sudo tee /etc/postgresql/16/main/conf.d/nominatim.conf > /dev/null << 'EOF'
# Nominatim tuning (https://nominatim.org/release-docs/latest/admin/Installation/)
# For WSL with ~48 GB. With 24 GB: maintenance_work_mem = 4GB, effective_cache_size = 12GB.
shared_buffers = 2GB
maintenance_work_mem = 6GB
autovacuum_work_mem = 2GB
work_mem = 50MB
effective_cache_size = 24GB
synchronous_commit = off
max_wal_size = 1GB
checkpoint_timeout = 60min
checkpoint_completion_target = 0.9
random_page_cost = 1.0
wal_level = minimal
max_wal_senders = 0
EOF
```

**Ubuntu**, restart PostgreSQL:

```bash
sudo systemctl restart postgresql
```

### A7. Create the database users

Type these **exactly as shown**. `$USER` is filled in automatically with your
Linux user name (check with `echo $USER`); `postgres` and `www-data` are fixed
system names, not placeholders.

**Ubuntu** (a database user with full rights, for running the import):

```bash
sudo -u postgres createuser -s $USER
```

**Ubuntu** (a read-only database user the web server uses):

```bash
sudo -u postgres createuser www-data
```

`role "…" already exists` means that step was already done; carry on.

### A8. Install Nominatim

**Ubuntu** (creates a Python environment and installs Nominatim; a few minutes):

```bash
python3 -m venv ~/nominatim-venv && ~/nominatim-venv/bin/pip install --upgrade pip && ~/nominatim-venv/bin/pip install "psycopg[binary]" nominatim-db nominatim-api falcon uvicorn gunicorn
```

**Ubuntu** (make the `nominatim` command available in every new terminal):

```bash
echo 'source ~/nominatim-venv/bin/activate' >> ~/.bashrc && source ~/nominatim-venv/bin/activate
```

**Ubuntu**, check:

```bash
nominatim --version
```

Expected: `Nominatim version 5.3.x`. The prompt now starts with `(nominatim-venv)`.

### A9. Download the data

**Ubuntu**, create the project folder:

```bash
mkdir -p ~/nominatim-project && cd ~/nominatim-project
```

**Ubuntu**, download the US extract (12 GB; measured ~10 minutes, but
Geofabrik's speed varies). Wait until it shows 100% and the prompt returns:

```bash
wget https://download.geofabrik.de/north-america/us-latest.osm.pbf
```

**Ubuntu**, verify the download:

```bash
wget -q https://download.geofabrik.de/north-america/us-latest.osm.pbf.md5 && md5sum -c us-latest.osm.pbf.md5
```

Expected: **`us-latest.osm.pbf: OK`**. If it says `FAILED`, delete the file
(`rm us-latest.osm.pbf`) and download again.

**Ubuntu**, optional but recommended extra data (better ranking and US ZIP code
centroids; about a minute):

```bash
wget https://nominatim.org/data/wikimedia-importance.csv.gz && wget -O secondary_importance.sql.gz https://nominatim.org/data/wikimedia-secondary-importance.sql.gz && wget https://nominatim.org/data/us_postcodes.csv.gz
```

**Ubuntu**, check:

```bash
ls -lh ~/nominatim-project
```

Expected: `us-latest.osm.pbf` (12G), `us-latest.osm.pbf.md5`,
`wikimedia-importance.csv.gz` (~307M), `secondary_importance.sql.gz` (~7M),
`us_postcodes.csv.gz` (~390K). Odd dates are normal (they are the files' dates
on the server). Files with these names in the project folder are picked up by the
import automatically.

### A10. Configure the import

**Ubuntu** (one line; writes the settings file `.env`):

```bash
printf 'NOMINATIM_IMPORT_STYLE=extratags\nNOMINATIM_FLATNODE_FILE=/home/%s/nominatim-flatnode/flatnode.file\n' "$USER" > ~/nominatim-project/.env && mkdir -p ~/nominatim-flatnode && cat ~/nominatim-project/.env
```

Expected output (with your user name):

```
NOMINATIM_IMPORT_STYLE=extratags
NOMINATIM_FLATNODE_FILE=/home/yourname/nominatim-flatnode/flatnode.file
```

### A11. Start the import

Check section 2 once more
(updates paused, sleep off, plugged in).

**Ubuntu**, open a `tmux` session so the import survives closing the window.
Paste **only this line**:

```bash
tmux new -s import
```

The window clears and a green bar appears at the bottom: you are inside tmux.

**Ubuntu (inside tmux)**, start the import:

```bash
cd ~/nominatim-project && nominatim import --osm-file us-latest.osm.pbf --no-updates --threads $(nproc) 2>&1 | tee setup.log
```

Within seconds you should see `Creating database`, `Setting up country tables`,
`Importing OSM data file`, then a fast-changing `Processing: Node(…)` counter.

- **Leave tmux** (import keeps running): press `Ctrl+B`, release, press `D`.
- **Come back later:** open Ubuntu and run `tmux attach -t import`.
- **Watch progress without attaching:** `tail -3 ~/nominatim-project/setup.log`.

### What happens, and how long it takes (measured)

| Phase | Log shows | Time |
|---|---|---|
| Load nodes | `Processing: Node(…)` | 19 min |
| Load ways (roads, buildings) | `Way(…)` | 7 h 27 min |
| Load relations (boundaries, routes) | `Relation(…)` | 1 h 16 min |
| osm2pgsql clustering and indexing, then the flatnode file is deleted | `Clustering table…`, `Building index on table 'planet_osm_ways'` | ≥ 20 min (not measured to the end: the tested run was interrupted here) |
| Wikipedia data, tables and functions | `Importing wikipedia…`, `Create functions…`, `Create tables` | 1 min |
| Copy into `placex` | `Load data into placex table` | 16 min |
| Postcodes | `Calculate postcodes` | 7 min |
| Indexing boundaries and ranks 1–25 (states, counties, cities, …) | `Starting boundaries rank …`, `Starting rank 5` … `rank 25` | 7 min |
| Indexing streets (ranks 26–27) | `… per second - rank 26 ETA (seconds): …` | 1 h 31 min |
| Indexing houses and POIs (ranks 28–30) | `Starting rank 30` | 3 h 25 min |
| Interpolation lines, unranked places (rank 0), postcodes | `Starting interpolation lines`, `Starting rank 0`, `Starting postcodes` | 27 min |
| Search indexes, drop update tables, word counts | `Post-process tables`, `Recompute word counts` | 17 min |
| **Done** | **`Import completed successfully`** | **~15.5 h in total** |

The indexing lines show an `ETA (seconds)` for the **current rank only**, not the
whole import. Resuming an interrupted indexing phase is cheap: in the tested run,
already-finished ranks 1–25 were re-checked in under a minute.

### If the import stops

Stop cleanly if you have to: `tmux attach -t import`, then `Ctrl+C`. After a
restart or power loss PostgreSQL recovers by itself (in the tested run it did,
twice). Then find the last phase in the log:

**Ubuntu:**

```bash
grep -a -E "^20[0-9-]+ [0-9:]+: [A-Z]" ~/nominatim-project/setup.log | tail -5
```

Then pick the matching case. Run the command inside a new `tmux new -s import`
session, as in A11.

**Stopped during `Indexing places` / `Starting rank …` or later**: resume indexing
(already indexed places are kept):

```bash
cd ~/nominatim-project && nominatim import --continue indexing --no-updates --threads $(nproc) 2>&1 | tee -a setup.log
```

**Stopped during `Load data into placex table` or `Calculate postcodes`**:

```bash
cd ~/nominatim-project && nominatim import --continue load-data --no-updates --threads $(nproc) 2>&1 | tee -a setup.log
```

**Stopped during `Processing: Node/Way/Relation`**: start over.

```bash
dropdb nominatim; rm -f ~/nominatim-flatnode/flatnode.file
```

then repeat A11.

**Stopped after the loading finished but before `Load data into placex table`**
(the last lines are `Building index on table 'planet_osm_ways'`, `Importing
wikipedia importance data`, or `Create functions`/`Create tables`): this happened
in the tested run. `--continue load-data` alone fails here, because it skips
creating Nominatim's tables. Instead of re-importing (~9 hours), run the missing
setup steps first; see *Advanced: resuming after the data load* near the end of
this guide.

### A12. Check the database

When the log ends with `Import completed successfully`, **Ubuntu:**

```bash
cd ~/nominatim-project && nominatim admin --check-database
```

Expected: every line ends in `OK`, except `wikipedia/wikidata data … not
applicable` and `TIGER external data table … not applicable` (both normal here).

The flatnode file was already deleted by the import (`--no-updates`). The
download is no longer needed; free 12 GB inside Linux with:

```bash
rm ~/nominatim-project/us-latest.osm.pbf
```

(This does not shrink the virtual disk file on `C:`; see *Disk space* in
section 1.)

### A13. Create a start script for the server

**Ubuntu** (paste the whole box; it writes the file `~/start-nominatim.sh`):

```bash
cat > ~/start-nominatim.sh << 'EOF'
#!/bin/bash
# Start the local Nominatim server on http://127.0.0.1:8088
WORKERS="${NOMINATIM_WORKERS:-8}"
sudo -n systemctl start postgresql 2>/dev/null   # usually already running
source ~/nominatim-venv/bin/activate
cd ~/nominatim-project
echo "Starting Nominatim on http://127.0.0.1:8088 with $WORKERS workers (log: ~/nominatim-project/server.log)"
exec gunicorn -b 127.0.0.1:8088 -w "$WORKERS" -k uvicorn.workers.UvicornWorker \
     "nominatim_api.server.falcon.server:run_wsgi()" >> ~/nominatim-project/server.log 2>&1
EOF
```

8 workers suit 10 CPU cores for WSL; with more cores, set e.g.
`NOMINATIM_WORKERS=12` before starting.

### A14. Start, check and stop the server

**Ubuntu**, start it in the background (you can close the window afterwards):

```bash
tmux new-session -d -s nominatim-server bash ~/start-nominatim.sh
```

**Check it:** after about 10 seconds open <http://127.0.0.1:8088/status> in a
Windows browser. Expected: `OK`. Try
<http://127.0.0.1:8088/search?q=350+5th+Ave+New+York&format=jsonv2>.

Use `127.0.0.1` rather than `localhost`: with some Windows tools (e.g. `curl.exe`)
`localhost` added ~220 ms per request.

**Ubuntu**, stop it:

```bash
tmux kill-session -t nominatim-server
```

**PowerShell**, free WSL's memory completely (also stops PostgreSQL and the
server):

```powershell
wsl --shutdown
```

After a Windows restart or `wsl --shutdown`, start the server again with the
first command of this step. The database stays on disk.

---

## Using the server from Julia

```julia
using Nominatim

client = NominatimClient(base_url = "http://127.0.0.1:8088")
server_status(client)

geocode("1600 Pennsylvania Ave NW, Washington, DC 20500"; client)

results = geocode_batch(addresses_dataframe; client,
                        countrycodes = "us",
                        concurrent_requests = 12,
                        checkpoint_file = "addresses.checkpoint.jsonl")
```

Measured throughput and tips are on the [bulk geocoding page](bulk.md): about
13 queries/s right after the server starts, ~50/s after the first ~1,500 new
addresses, ~100/s for addresses it has seen before.

---

## Advanced: resuming after the data load

Use this only for the case described in *If the import stops* (in Path A):
osm2pgsql finished loading (the log shows `Processed … relations`), but the
import stopped before `Load data into placex table`. It runs the steps that
`nominatim import` performs between osm2pgsql and loading, taken from Nominatim
5.3.2's `SetupAll._base_import`, then continues normally. Tested once, on 5.3.2.

**Ubuntu**, check that the loaded data is there and Nominatim's tables are not
(expect a number in the millions, then `f`):

```bash
psql -d nominatim -Atc "SELECT reltuples::bigint FROM pg_class WHERE relname = 'place'" && psql -d nominatim -Atc "SELECT to_regclass('public.placex') IS NOT NULL"
```

**Ubuntu**, the flatnode file is not needed anymore; delete it (~113 GB):

```bash
rm -f ~/nominatim-flatnode/flatnode.file
```

**Ubuntu** (paste the whole box; writes a small Python script):

```bash
cat > ~/nominatim-project/finish_base_import.py << 'EOF'
"""Run the part of `nominatim import` between osm2pgsql and `--continue load-data`."""
import logging, sys
from pathlib import Path
from nominatim_db.clicmd.setup import SetupAll
from nominatim_db.config import Configuration
from nominatim_db.data import country_info
from nominatim_db.db.connection import connect
from nominatim_db.tools import refresh

logging.basicConfig(stream=sys.stderr, format='%(asctime)s: %(message)s',
                    datefmt='%Y-%m-%d %H:%M:%S', level=logging.WARNING)
project_dir = Path.cwd().resolve()
config = Configuration(project_dir)
country_info.setup_country_config(config)
dsn = config.get_libpq_dsn()

with connect(dsn) as conn, conn.cursor() as cur:
    cur.execute("SELECT to_regclass('public.placex') IS NOT NULL")
    if cur.fetchone()[0]:
        sys.exit('placex already exists: run nominatim import --continue load-data instead.')

logging.warning('Importing wikipedia importance data')
refresh.import_wikipedia_articles(dsn, Path(config.WIKIPEDIA_DATA_PATH or project_dir))
logging.warning('Importing secondary importance raster data')
refresh.import_secondary_importance(dsn, project_dir)
SetupAll()._setup_tables(config, False)
logging.warning('Done. Now run: nominatim import --continue load-data --no-updates')
EOF
```

**Ubuntu**, run it (a few minutes; ends with `Done. Now run: …`):

```bash
cd ~/nominatim-project && ~/nominatim-venv/bin/python3 finish_base_import.py 2>&1 | tee -a setup.log
```

Then, in a `tmux new -s import` session, continue:

```bash
cd ~/nominatim-project && nominatim import --continue load-data --no-updates --threads $(nproc) 2>&1 | tee -a setup.log
```

---

## Path B: Docker (untested)

> **Untested:** this path was not tried. It follows the
> [mediagis/nominatim-docker how-to](https://github.com/mediagis/nominatim-docker/blob/master/howto.md)
> for image version 5.3. Docker Desktop needs a paid subscription for
> organisations with more than 250 employees or more than USD 10 million revenue.

The [mediagis/nominatim](https://github.com/mediagis/nominatim-docker) image
downloads the data, imports it and starts the API in one command. It runs on the
same WSL2 machinery, so the disk, memory and "stop Windows from interrupting"
advice above applies.

1. Create `.wslconfig` as in step A1.
2. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) with
   the default *"Use WSL 2 based engine"*.

**PowerShell** (one command; the backticks continue the line):

```powershell
docker run -d --name nominatim `
  --shm-size=16g `
  -e PBF_URL=https://download.geofabrik.de/north-america/us-latest.osm.pbf `
  -e IMPORT_STYLE=extratags `
  -e IMPORT_WIKIPEDIA=true `
  -e IMPORT_SECONDARY_WIKIPEDIA=true `
  -e IMPORT_US_POSTCODES=true `
  -e IMPORT_TIGER_ADDRESSES=false `
  -e FREEZE=true `
  -e THREADS=10 `
  -e GUNICORN_WORKERS=8 `
  -e POSTGRES_MAINTENANCE_WORK_MEM=6GB `
  -e POSTGRES_EFFECTIVE_CACHE_SIZE=24GB `
  -e NOMINATIM_PASSWORD=choose_a_password `
  -v nominatim-data:/var/lib/postgresql/16/main `
  -v nominatim-flatnode:/nominatim/flatnode `
  -p 8080:8080 `
  mediagis/nominatim:5.3
```

**PowerShell**, watch the import (`Ctrl+C` stops watching, not the import):

```powershell
docker logs -f nominatim
```

It is done when <http://127.0.0.1:8080/status> answers `OK`. Stop and start later
with `docker stop nominatim` and `docker start nominatim`; the data stays in the
`nominatim-data` volume.

---

## Maintenance and troubleshooting

### Common problems

| Symptom | Cause and fix |
|---|---|
| Laptop restarted overnight | Windows Update. Pause updates (section 2), then see *If the import stops* (in Path A). |
| `.env` missing, or commands after `tmux new` did nothing | Several commands were pasted together with `tmux new`. Paste one box at a time. |
| `nominatim: command not found` | Run `source ~/nominatim-venv/bin/activate`. |
| Import stops with "No space left on device" | Disk full. Free space on `C:`, then see *If the import stops* (in Path A). |
| Import killed, `dmesg` mentions "Out of memory" | Lower `maintenance_work_mem` or `--threads`, or raise `memory=` in `.wslconfig`. |
| Import very slow (days) | Data is on a hard disk or under `/mnt/c`. Keep it in the Linux home folder on an SSD. |
| Log says `checkpoints are occurring too frequently` | Harmless during the import. |
| `http://127.0.0.1:8088` not reachable from Windows | The server is not running (after a restart or `wsl --shutdown`): start it (A14). |
| API returns `Database connection failed` | PostgreSQL is not running: `sudo systemctl start postgresql`. |
| `permission denied for table …` in the API | The `www-data` database user is missing: `sudo -u postgres createuser www-data`, then `nominatim refresh --website`. |

### Refreshing the data

With `--no-updates` the database cannot follow OpenStreetMap changes. For newer
data, download a fresh extract and import again into a new database. Record the
data date with your results: `server_status(client).data_updated` in Julia.

### Adding TIGER later

TIGER needs the update tables, so it only works on a database imported **without**
`--no-updates`. See the
[Nominatim TIGER docs](https://nominatim.org/release-docs/latest/customize/Tiger/).
Nominatim.jl flags interpolated results either way.

### Moving WSL to another drive (untested)

**PowerShell** (needs WSL 2.5 or newer; check with `wsl --version`):

```powershell
wsl --shutdown
```

```powershell
wsl --manage Ubuntu-24.04 --move E:\WSL\Ubuntu-24.04
```

### Getting disk space back on `C:`

The virtual disk file keeps its largest size. In the tested run it was 226 GB
after the import while Linux used only 94 GB. Compacting it shrank the file to
**95 GB** and freed **131 GB** on `C:` (*measured*), in about 15 minutes. The
database passed `nominatim admin --check-database` afterwards.

Stop the server first (A14). Optional but sensible: make a backup copy (about the
size of the used space), and delete it once everything works again:

```powershell
wsl --export Ubuntu-24.04 "$env:USERPROFILE\ubuntu-nominatim-backup.tar"
```

**Ubuntu**, delete the download if it is still there:

```bash
rm -f ~/nominatim-project/us-latest.osm.pbf
```

**Ubuntu**, tell the virtual disk which space is empty (asks for your password):

```bash
sudo fstrim -av
```

Expected: a line like `/: 901.7 GiB (…) trimmed on /dev/sdd`. The large number is
the empty part of the virtual disk's 1 TB maximum; nothing is deleted.

**PowerShell**, close the Ubuntu window, then:

```powershell
wsl --shutdown
```

**PowerShell**, find the virtual disk file (copy the path it prints):

```powershell
(Get-ChildItem -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss | Where-Object { $_.GetValue("DistributionName") -eq 'Ubuntu-24.04' }).GetValue("BasePath") + "\ext4.vhdx"
```

**PowerShell as administrator** (right-click PowerShell → *Run as administrator*):

```powershell
diskpart
```

At the `DISKPART>` prompt, type these one at a time, with your path in the first
line:

```
select vdisk file="C:\Users\yourname\AppData\Local\wsl\{…}\ext4.vhdx"
```

```
attach vdisk readonly
```

```
compact vdisk
```

Wait for `DiskPart successfully compacted the virtual disk file.` Do not open
Ubuntu meanwhile.

```
detach vdisk
```

```
exit
```

### Not using your own PC

Everything in Path A (from A4 on) works on any Ubuntu 24.04 machine, such as a
university server or a cloud VM with enough SSD space. Point `base_url` at that
machine, behind a firewall or SSH tunnel: never expose an open geocoder to the
internet.

---

## Sources

- [Nominatim installation](https://nominatim.org/release-docs/latest/admin/Installation/) and [Ubuntu 24.04 guide](https://nominatim.org/release-docs/latest/admin/Install-on-Ubuntu-24/)
- [Nominatim import](https://nominatim.org/release-docs/latest/admin/Import/)
- [mediagis/nominatim-docker how-to](https://github.com/mediagis/nominatim-docker/blob/master/howto.md)
- [WSL configuration](https://learn.microsoft.com/en-us/windows/wsl/wsl-config) and [WSL disk space](https://learn.microsoft.com/en-us/windows/wsl/disk-space)
- [Geofabrik US extract](https://download.geofabrik.de/north-america/us.html)
- [Nominatim usage policy](https://operations.osmfoundation.org/policies/nominatim/)
