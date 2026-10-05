# Slurm Configuration Discovery

This repository contains a collection of Bash/Python utilities for discovering a user's effective Slurm configuration and turning it into a generic, machine-readable representation.

The complete workflow is orchestrated by:

```bash
./slurm-discover.sh
```

The workflow progressively turns the site-specific Slurm configuration into:

```text
slurm.yaml
    ↓
options.yaml
    ↓
architecture.json
    ↓
slurm.json
    ↓
options-final.yaml
```

## Repository layout

```text
slurm-discover.sh
slurm-user-info.sh
get_slurm_data.sh
slurm-resolve-options.sh
slurm-yaml2json.sh
architecture_collector.sh
```

### `slurm-discover.sh`

Top-level workflow/orchestrator.

It runs all discovery stages in the correct order:

1. Collect user/account information.
2. Collect Slurm configuration.
3. Resolve initial job options.
4. Detect CPU/accelerator architectures.
5. Create the filtered generic JSON.
6. Resolve the final job options again.

This is normally the only script that needs to be run for the complete workflow.

---

### `slurm-user-info.sh`

Collects user-specific Slurm accounting information.

It determines things such as:

* accounts available to the user
* QOS available through each account
* default QOS information

The output is stored in:

```text
user.json
```

This is intentionally kept separate from the generic cluster configuration because it contains user/account-specific information.

---

### `get_slurm_data.sh`

Queries the Slurm configuration and produces the main YAML representation.

It collects information such as:

* partitions
* QOS
* QOS limits
* hardware characteristics
* CPU granularity
* memory
* GPU availability
* partition limits
* node counts
* account/partition relationships

The output is normally:

```text
slurm.yaml
```

This is the primary discovery data used by the rest of the workflow.

---

### `slurm-resolve-options.sh`

Resolves the discovered Slurm configuration into concrete job allocations.

It determines usable combinations of things such as:

* partition
* account
* QOS
* nodes
* tasks
* CPUs per task
* GPUs
* walltime
* minimum allocations
* maximum allocations

The first invocation produces:

```text
options.yaml
```

This is an intermediate file used by architecture detection.

After architecture detection, the resolver is run a second time against the filtered generic JSON. That produces:

```text
options-final.yaml
```

The second file is the final options representation and contains only partitions that survived architecture filtering.

---

### `architecture_collector.sh`

Runs architecture detection on the compute partitions.

It reads `options.yaml`, takes the generated minimum allocation for each partition, and uses `srun` to execute EESSI architecture detection:

```text
eessi_archdetect.sh cpupath
eessi_archdetect.sh accelpath
```

The results are stored in:

```text
architecture.json
```

For example:

```json
{
  "version": 1,
  "partitions": {
    "cpu": {
      "cpu": "x86_64/amd/zen4",
      "accelerator": null
    },
    "gpu": {
      "cpu": "x86_64/amd/zen4",
      "accelerator": "accel/nvidia/cc90"
    }
  }
}
```

## Important: `architecture_collector.sh` may need adaptation

**This is the most cluster-specific script in the repository.**

Do not assume that `architecture_collector.sh` will work unchanged on another cluster.

The general approach is portable, but clusters can have different requirements for launching even a minimal `srun` job.

You may need to adjust or "massage" the collector for the target environment.

Possible differences include:

* required Slurm constraints
* account requirements
* QOS requirements
* job names
* partition-specific options
* node features
* module/environment setup
* EESSI installation paths
* how `eessi_archdetect.sh` is exposed
* accelerator configuration
* site-specific Slurm policies
* minimum job sizes
* time limits
* special `srun` options

The collector supports additional `srun` options through:

```bash
ARCHDETECT_SRUN_OPTIONS
```

For example:

```bash
ARCHDETECT_SRUN_OPTIONS="--constraint=foo --job-name=eessi-archdetect" ./slurm-discover.sh
```

This is useful for simple site-specific requirements.

However, if the site requires environment setup or more complicated logic, edit `architecture_collector.sh` directly.

A good way to integrate a new cluster is to test architecture detection on **one partition manually first**, then adapt the collector once that command is known to work.

### Account fallback

Not every account may be allowed to use every partition. For each partition,
`architecture_collector.sh` tries the minimum allocation of every
account/QOS combination in `options.yaml` in turn and stops at the first one
that succeeds. A partition only counts as failed if all of them failed.

### Recording how to use EESSI (`eessi.json`)

Some sites need extra `srun` options before EESSI is usable (for example
`--constraint=eessi` on LUMI, or `_CVMFS_` in the job name on Leonardo), and
sites recommend specific steps to load EESSI. Since this is independent of the
partition, `slurm_discover.sh` stores it in a separate `eessi.json`:

```bash
ARCHDETECT_SRUN_OPTIONS="--constraint=eessi" \
EESSI_LOAD_COMMANDS=$'module load EESSI/2026.06' \
./slurm_discover.sh
```

```json
{
  "version": 1,
  "srun_options": ["--constraint=eessi"],
  "load_commands": ["module load EESSI/2026.06"]
}
```

Values not given in the environment are kept from an existing `eessi.json`.

---

## Incremental architecture detection

`architecture_collector.sh` is intentionally incremental.

If `architecture.json` already exists, partitions that are already present are not rerun.

For example:

```json
{
  "partitions": {
    "cpu": {
      "cpu": "x86_64/amd/zen4",
      "accelerator": null
    }
  }
}
```

means that `cpu` will be skipped on subsequent runs.

If detection for `gpu` previously failed, there will be no `gpu` entry, so the next run will try it again.

This makes it possible to progressively fill holes.

For example:

```bash
ARCHDETECT_SRUN_OPTIONS="--constraint=gpu-feature" ./slurm-discover.sh
```

Existing successful entries are preserved.

Failed partitions remain absent from `architecture.json`.

---

### `slurm-yaml2json.sh`

Converts the discovered YAML into a generic JSON representation.

Without an architecture file:

```bash
./slurm-yaml2json.sh slurm.yaml slurm.json
```

all discovered partitions are included.

With an architecture file:

```bash
./slurm-yaml2json.sh slurm.yaml slurm.json architecture.json
```

only partitions present in `architecture.json` are included.

The detected architecture is also added to each partition.

For example:

```json
{
  "partitions": {
    "gpu": {
      "hardware": {
        "cores_per_node": 128,
        "gpus_per_node": 4
      },
      "architecture": {
        "cpu": "x86_64/amd/zen4",
        "accelerator": "accel/nvidia/cc90"
      }
    }
  }
}
```

Therefore `architecture.json` acts as the filter between raw Slurm discovery and the final generic configuration.

---

# Complete workflow

The normal entry point is:

```bash
./slurm-discover.sh
```

By default the current Unix user is used.

A different user can be selected with:

```bash
USER_NAME=eualano ./slurm-discover.sh
```

An account can optionally be supplied:

```bash
USER_NAME=eualano ACCOUNT=d2026d04-065-users ./slurm-discover.sh
```

If architecture detection needs additional Slurm options:

```bash
ARCHDETECT_SRUN_OPTIONS="--constraint=foo --job-name=eessi-archdetect" ./slurm-discover.sh
```

---

# Workflow in detail

The complete pipeline is:

```text
                         Slurm
                           │
                           ▼
                ┌────────────────────┐
                │ slurm-user-info.sh │
                └─────────┬──────────┘
                          │
                      user.json
                          │
                          │
                ┌─────────▼──────────┐
                │ get_slurm_data.sh  │
                └─────────┬──────────┘
                          │
                      slurm.yaml
                          │
                          ▼
              ┌─────────────────────────┐
              │ slurm-resolve-options.sh│
              └────────────┬────────────┘
                           │
                      options.yaml
                           │
                           ▼
              ┌─────────────────────────┐
              │ architecture_collector  │
              └────────────┬────────────┘
                           │
                   architecture.json
                           │
                           ▼
              ┌─────────────────────────┐
              │ slurm-yaml2json.sh      │
              └────────────┬────────────┘
                           │
                       slurm.json
                           │
                           ▼
              ┌─────────────────────────┐
              │ slurm-resolve-options.sh│
              └────────────┬────────────┘
                           │
                   options-final.yaml
```

The first options pass is necessary because the architecture collector needs concrete `srun` commands.

The second options pass is necessary because architecture detection can eliminate partitions.

Thus:

```text
options.yaml
```

is the **discovery/intermediate** options file, while:

```text
options-final.yaml
```

is the **final filtered** options file.

---

# Output files

A normal run produces:

| File                 | Purpose                                        |
| -------------------- | ---------------------------------------------- |
| `user.json`          | User-specific account/QOS information          |
| `slurm.yaml`         | Raw/effective Slurm configuration              |
| `options.yaml`       | Initial resolved job options                   |
| `architecture.json`  | Detected architecture per partition            |
| `slurm.json`         | Generic JSON filtered by detected architecture |
| `options-final.yaml` | Final options matching `slurm.json`            |

The two main final outputs are:

```text
slurm.json
options-final.yaml
```

The intermediate files are deliberately retained so that individual stages can be inspected and debugged.

---

# Requirements

The workflow assumes a working Slurm environment.

Required software includes:

* Bash
* Python 3
* PyYAML
* `scontrol`
* `sacctmgr`
* `srun`

Architecture detection additionally requires:

* EESSI
* `eessi_archdetect.sh`

The user running the workflow must have sufficient Slurm/accounting permissions for the queries performed by the scripts.

---

# Installation

Make the scripts executable:

```bash
chmod +x slurm-discover.sh
chmod +x slurm-user-info.sh
chmod +x get_slurm_data.sh
chmod +x slurm-resolve-options.sh
chmod +x slurm-yaml2json.sh
chmod +x architecture_collector.sh
```

Then run:

```bash
./slurm-discover.sh
```

---

# Adapting to a new cluster

When bringing this repository to a new cluster, it is recommended to work through the pipeline incrementally.

First verify:

```text
slurm-user-info.sh
```

Then:

```text
get_slurm_data.sh
```

Inspect:

```text
slurm.yaml
```

and make sure the discovered partitions, hardware, QOS and limits look sensible.

Next run:

```text
slurm-resolve-options.sh
```

and inspect:

```text
options.yaml
```

The generated minimum allocations should be usable on the target cluster.

Only after those stages work should you concentrate on:

```text
architecture_collector.sh
```

Test one partition first.

Once EESSI architecture detection works manually, adapt the collector as necessary and then run the complete workflow.

This is particularly important because architecture detection actually submits jobs to the cluster, whereas most of the other stages are configuration/accounting queries.

---

# Caveats

Slurm installations can differ substantially.

This repository does not attempt to model every possible Slurm configuration or site policy.

Potential differences include:

* accounting configuration
* QOS policy
* partition access rules
* node constraints
* GRES configuration
* CPU allocation semantics
* memory allocation semantics
* GPU configuration
* environment/module setup
* EESSI availability
* site-specific `srun` requirements

The scripts therefore make some assumptions about the information exposed by the local Slurm installation.

In particular:

> **`architecture_collector.sh` should be considered a site-integration component, not a universally plug-and-play script.**

It may require changes for the target cluster.

---

# Design principle

The repository deliberately separates three kinds of information:

### Site configuration

```text
slurm.yaml
```

What Slurm says exists and what policies apply.

### Observed architecture

```text
architecture.json
```

What was actually detected by running on compute resources.

### Generic usable configuration

```text
slurm.json
```

The site configuration restricted to partitions for which architecture detection succeeded, with the detected architecture attached.

The final options are then generated from that filtered configuration:

```text
options-final.yaml
```

This makes the final output suitable for downstream consumers that need a generic description of what can actually be used on the cluster.
