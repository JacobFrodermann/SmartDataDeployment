#!/usr/bin/env python3
"""Install demo jobs, chains and chain runs into the Smart*Jobs stack.

Purpose: give the replay/chain handling of SmartDataJobs (commit f807541)
realistic data to look at, either in the admin pages or through
GET /SmartDataJobs/smartdatajobs/jobexecution/replay.

Everything that is a *definition* (datajobs, datajobs_params,
datajobs_chain, datajobs_join_oo) is created through the normal SmartData
REST routes - exactly what the admin setup pages do.

The *runs* (datajobs_log) are written with psql instead. Two reasons:

 1. Runs are produced by executing jobs; there is no REST route to say
    "run job X, record result Y at time T". Replaying real jobs would
    fire the actions (write rows, delete rows) and would produce a log
    that depends on the moment it was created - not reproducible.
 2. SmartData cannot write PostgreSQL *uuid* columns over REST at all.
    DynRecordsPostgres.setPlaceholder() has no `uuid` case, so the
    placeholder of datajobs_log.runid / chainrunid / parentrunid /
    replayofrunid is never bound and every insert fails with
    "No value specified for parameter N" (verified on the running stack).
    The run bookkeeping columns are all uuid, so seeding them over REST
    is impossible, not merely inconvenient.

Environment variables SMARTUSER_DB_PASSWORD etc. are read the same way
docker/payara/init_0_configure_databases.sh does; only psql needs them.

Idempotency: jobs are identified by the (reserved) name prefix
``Demo - ``. The script deletes all of them (params, chain edges, log
rows and object links cascade on the foreign keys) and recreates them,
so it can be re-run at any time.

Usage:
    python3 scripts/demo_jobs_data.py                # install / reinstall
    python3 scripts/demo_jobs_data.py --dryrun       # show what it would do
    python3 scripts/demo_jobs_data.py --remove       # delete the demo rows only

Environment:
    SMARTDATA_BASE  default http://localhost:8080/SmartData
    STORAGE         default smartmonitoring
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import subprocess
import uuid

SMARTDATA = os.environ.get("SMARTDATA_BASE", "http://localhost:8080/SmartData")
STORAGE = os.environ.get("STORAGE", "smartmonitoring")
PREFIX = "Demo - "

# Fixed namespace so the synthetic run ids are stable across installs.
RUN_NS = uuid.UUID("6f9619ff-8b86-d011-b42d-00cf4fc964ff")

# Deterministic anchor for all timestamps (UTC). Every run is placed by an
# offset from this anchor, so a reinstall reproduces exactly the same log.
import datetime as _dt

ANCHOR = _dt.datetime(2026, 11, 26, 8, 0, 0, tzinfo=_dt.timezone.utc)


# --------------------------------------------------------------------------
# HTTP helpers
# --------------------------------------------------------------------------
def parse_body(raw):
    """SmartData answers JSON for most routes, but a bulk POST of records
    returns the new ids as a bare comma separated list (e.g. "18,19,20")."""
    text = raw.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    if all(part.strip().lstrip("-").isdigit() for part in text.split(",")):
        return [int(part) for part in text.split(",")]
    return text


def call(method, path, params=None, body=None):
    url = SMARTDATA.rstrip("/") + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, parse_body(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as ex:
        return ex.code, parse_body(ex.read().decode("utf-8", "replace"))


def records(collection, **params):
    params.setdefault("storage", STORAGE)
    return call("GET", "/smartdata/records/" + collection, params)


def create(collection, rows):
    status, body = call("POST", "/smartdata/records/" + collection,
                        {"storage": STORAGE}, rows)
    if status != 201:
        raise SystemExit("Creating %s failed (%s): %s" % (collection, status, body))
    return body


def delete(collection, **params):
    params.setdefault("storage", STORAGE)
    return call("DELETE", "/smartdata/records/" + collection, params)


# --------------------------------------------------------------------------
# Run log helpers
# --------------------------------------------------------------------------
def ts(minutes):
    return (ANCHOR + _dt.timedelta(minutes=minutes)).isoformat()


def rid(name):
    return str(uuid.uuid5(RUN_NS, name))


def run(*, job, step, chain, runid, parent, runstate, result, at_minutes,
        attempt=1, input_snapshot=None, errorclass=None, durationms=None,
        replayof=None, replayreason=None, inputfromrunid=None,
        resultreused=False, resultvaliduntil=None, processed=False):
    """Builds one datajobs_log row exactly as JobRunner.runJobAsync() writes it."""
    iserror = runstate in ("failed", "error")
    wastimeout = runstate == "timeout"
    snapshot = input_snapshot if input_snapshot is not None else {}
    snapshot_json = json.dumps(snapshot, sort_keys=True, separators=(",", ":"))
    import hashlib
    row = {
        "datajob_id": job,
        "result": json.dumps(result, sort_keys=True),
        "ts": ts(at_minutes),
        "iserror": iserror,
        "wastimeout": wastimeout,
        "processed": bool(processed),
        "resultreused": bool(resultreused),
        "runid": runid,
        "chainrunid": chain,
        "step": step,
        "runstate": runstate,
        "input": snapshot_json,
        "inputhash": hashlib.sha256(snapshot_json.encode("utf-8")).hexdigest(),
        "attempt": attempt,
    }
    if parent is not None:
        row["parentrunid"] = parent
    if errorclass is not None:
        row["errorclass"] = errorclass
    if durationms is not None:
        row["durationms"] = durationms
    if replayof is not None:
        row["replayofrunid"] = replayof
    if replayreason is not None:
        row["replayreason"] = replayreason
    if inputfromrunid is not None:
        row["inputfromrunid"] = inputfromrunid
    if resultvaliduntil is not None:
        row["resultvaliduntil"] = resultvaliduntil
    return row


# --------------------------------------------------------------------------
# Demo content
# --------------------------------------------------------------------------
def demo_jobs():
    """Job definitions + params, keyed by a local slug.

    Every job is inactive and has no start/repeat: the demo data never
    executes anything by itself. Activating a job is a manual decision.
    """
    return [
        # ---- chain 1: sensor -> aggregate -> store -> notify -----------
        dict(slug="sensor", name="Demo - readSensorBatch",
             desc="Reads the latest sensor batch from the measurements collection",
             action="ReadData", priority=1,
             idempotent=True, reusable=True, resultttlsecs=900,
             resultttlbasis="wallclock", resultscope="chainrun",
             maxchaindepth=6,
             params=[
                 ("url", "/SmartData/smartdata/records/sensordata", "url"),
                 ("smartdataurl", "/SmartData", "url"),
                 ("requestmethod", "GET", "string"),
                 ("urlparams", '{"storage":"smartmonitoring","collection":"sensordata",'
                               '"filter":"synced,eq,false","order":"ts,DESC","size":50}',
                  "string"),
             ]),
        dict(slug="aggregate", name="Demo - aggregateSensorBatch",
             desc="Aggregates the batch of readSensorBatch into 15 minute clusters",
             action="ReadData", priority=1,
             idempotent=True, reusable=True, resultttlsecs=3600,
             resultttlbasis="wallclock", resultscope="chainrun",
             maxchaindepth=6,
             params=[
                 ("url", "/SmartData/smartdata/records/sensordata", "url"),
                 ("smartdataurl", "/SmartData", "url"),
                 ("requestmethod", "GET", "string"),
                 ("urlparams", '{"storage":"smartmonitoring","collection":"sensordata",'
                               '"order":"ts,DESC","size":1}', "string"),
             ]),
        dict(slug="store", name="Demo - storeAggregate",
             desc="Writes the aggregate into the archive collection",
             action="WriteData", priority=0,
             idempotent=False, reusable=False, resultttlsecs=0,
             resultttlbasis="wallclock", resultscope="chainrun",
             maxchaindepth=6,
             params=[
                 ("smartdataurl", "/SmartData", "url"),
                 ("storage", "smartmonitoring", "storage"),
                 ("collection", "datajobs_log", "collection"),
                 ("requestmethod", "POST", "string"),
                 ("prejobfield", "records", "string"),
                 ("urlparams", '{"storage":"teststorage","collection":"testcollection_ts"}',
                  "string"),
             ]),
        dict(slug="publish", name="Demo - publishAggregate",
             desc="Forwards the stored aggregate to the downstream consumer",
             action="WriteData", priority=0,
             idempotent=True, reusable=True, resultttlsecs=-1,
             resultttlbasis="wallclock", resultscope="chainrun",
             maxchaindepth=6,
             params=[
                 ("smartdataurl", "/SmartData", "url"),
                 ("requestmethod", "POST", "string"),
                 ("prejobfield", "records", "string"),
                 ("urlparams", '{"storage":"teststorage","collection":"testcollection_ts"}',
                  "string"),
             ]),
        # ---- chain 2: reachability -> pull -> cleanup -----------------
        dict(slug="checknet", name="Demo - checkArchiveReachable",
             desc="Checks that the SmartData archive answers",
             action="CheckNet", priority=2,
             idempotent=True, reusable=False, resultttlsecs=0,
             resultttlbasis="wallclock", resultscope="chainrun",
             maxchaindepth=6,
             params=[
                 ("url", "/SmartData/smartdata/system/info", "url"),
                 ("requestmethod", "GET", "string"),
                 ("statuscode", "200", "int"),
             ]),
        dict(slug="pull", name="Demo - pullArchivedData",
             desc="Pulls archived data from the external system",
             action="ReadData", priority=1,
             idempotent=True, reusable=True, resultttlsecs=1800,
             resultttlbasis="wallclock", resultscope="chainrun",
             maxchaindepth=6,
             params=[
                 ("url", "/SmartData/smartdata/records/testcollection_ts", "url"),
                 ("smartdataurl", "/SmartData", "url"),
                 ("requestmethod", "GET", "string"),
                 ("urlparams", '{"storage":"teststorage","collection":"testcollection_ts",'
                               '"size":20}', "string"),
             ]),
        dict(slug="cleanup", name="Demo - cleanupJobLog",
             desc="Deletes processed job log rows older than 14 days",
             action="DeleteData", priority=0,
             idempotent=False, reusable=False, resultttlsecs=0,
             resultttlbasis="wallclock", resultscope="chainrun",
             maxchaindepth=6,
             params=[
                 ("smartdataurl", "/SmartData", "url"),
                 ("storage", STORAGE, "storage"),
                 ("collection", "datajobs_log", "collection"),
                 ("days", "14", "int"),
                 ("filter", "processed,eq,true", "string"),
             ]),
        # ---- chain 3: guarded job that must not loop ------------------
        dict(slug="loop", name="Demo - guardedChainStep",
             desc="Chain step guarded by maxchaindepth against a self-loop",
             action="ReadData", priority=0,
             idempotent=True, reusable=True, resultttlsecs=600,
             resultttlbasis="schedule", resultscope="chainrun",
             maxchaindepth=2,
             params=[
                 ("url", "/SmartData/smartdata/records/sensordata", "url"),
                 ("smartdataurl", "/SmartData", "url"),
                 ("requestmethod", "GET", "string"),
             ]),
    ]


def demo_chains():
    """(pre_slug, post_slug, edge attributes) — one row per datajobs_chain."""
    return [
        # chain 1: classic happy path chain, every hop conditioned on success
        ("sensor", "aggregate", dict(active=True, checkkey="state",
                                     checkvalue="finished", onerror="skip",
                                     propagateinput=True, reuseallowed=True)),
        ("aggregate", "store", dict(active=True, checkkey="state",
                                    checkvalue="finished", onerror="skip",
                                    propagateinput=True, reuseallowed=True,
                                    maxageresultsecs=3600)),
        ("store", "publish", dict(active=True, checkkey="state",                
                                 checkvalue="finished", onerror="skip",
                                 propagateinput=False, reuseallowed=True)),
        # compensation hop: runs the cleanup when the write failed
        ("store", "cleanup", dict(active=True, checkkey="state",
                                  checkvalue="failed", onerror="run",
                                  propagateinput=False, reuseallowed=False)),
        # chain 2: a failing predecessor must stop this chain run
        ("checknet", "pull", dict(active=True, checkkey="recivedStatusCode",
                                  checkvalue="200", onerror="fail",
                                  propagateinput=True, reuseallowed=False,
                                  maxretries=2, retrydelaysecs=30)),
        ("pull", "cleanup", dict(active=True, checkchanged="records",
                                 onerror="skip", propagateinput=False,
                                 reuseallowed=False)),
        # chain 3: self-loop to demo the maxchaindepth guard
        ("loop", "loop", dict(active=True, onerror="skip",
                              propagateinput=True, reuseallowed=False,
                              maxretries=0, retrydelaysecs=0)),
    ]


def _snap(**params_and_pre):
    """Builds an input snapshot in the shape executeJob() writes it."""
    pre = params_and_pre.pop("prejobinfo", None)
    return {"params": params_and_pre, "prejobinfo": pre}


SENSOR_RESULT_OK = {
    "state": "finished",
    "records": [
        {"ts": "2026-11-26T07:59:00", "temperature_celsius": 18.4,
         "humidity_percent": 61.2, "pressure_hPa": 1008.1, "pm2_5": 7.3,
         "pm10_0": 11.9, "co2_ppm": 712},
        {"ts": "2026-11-26T07:59:25", "temperature_celsius": 18.5,
         "humidity_percent": 61.0, "pressure_hPa": 1008.2, "pm2_5": 7.1,
         "pm10_0": 11.6, "co2_ppm": 708},
    ],
    "usedTime_ms": 41,
}
AGG_RESULT_OK = {
    "state": "finished",
    "records": [{"ts": "2026-11-26T07:45:00", "inn_temp": 18.45,
                 "inn_hum": 61.1, "pm2_5": 7.2, "pm10_0": 11.75,
                 "co2": 710, "processed": True}],
    "usedTime_ms": 63,
}
STORE_RESULT_OK = {
    "saveMethod": "WriteDataAction/HTTP URL connection",
    "calledUrl": "/SmartData/smartdata/records/testcollection_ts"
                 "?storage=teststorage&collection=testcollection_ts",
    "httpStatus": 201,
    "response": "1",
    "state": "finished",
    "call_time_ms": 58,
}
STORE_RESULT_FAIL = {
    "saveMethod": "WriteDataAction/HTTP URL connection",
    "calledUrl": "/SmartData/smartdata/records/testcollection_ts"
                 "?storage=teststorage&collection=testcollection_ts",
    "httpStatus": 500,
    "statemsg": "Could not write data. API returned: 500",
    "state": "failed",
    "call_time_ms": 41,
}
PUBLISH_RESULT_OK = {
    "saveMethod": "WriteDataAction/HTTP URL connection",
    "calledUrl": "/SmartData/smartdata/records/testcollection_ts"
                 "?storage=teststorage&collection=testcollection_ts",
    "httpStatus": 201,
    "response": "1",
    "state": "finished",
    "call_time_ms": 47,
}
CHECKNET_OK = {
    "calledUrl": "/SmartData/smartdata/system/info",
    "recivedStatusCode": 200,
    "state": "finished",
}
CHECKNET_FAIL = {
    "calledUrl": "/SmartData/smartdata/system/info",
    "recivedStatusCode": 503,
    "state": "failed",
    "statemsg": "Statuscode >200< was expected but got >503<",
}
CLEANUP_RESULT_OK = {
    "state": "finished",
    "deleteMethod": "SmartDataAccessor/JDBC",
    "deleteResult": {"cutoffDate": "2026-11-12", "deletedCount": 42,
                     "success": True},
}


def demo_runs(ids):
    """Returns all datajobs_log rows. ids = slug -> job id."""
    rows = []
    j = ids

    # ================================================================
    # Chain run A — happy path, all four steps finished.
    # Root = readSensorBatch (step 0) -> aggregate (1) -> store (2) ->
    # notify (3). Finished chain runs have nothing to resume.
    # ================================================================
    A = rid("chainrun-A")
    A0 = rid("A-step0")
    A1 = rid("A-step1")
    A2 = rid("A-step2")
    A3 = rid("A-step3")
    rows += [
        run(job=j["sensor"], step=0, chain=A, runid=A0, parent=None,
            runstate="finished", result=SENSOR_RESULT_OK, at_minutes=0,
            durationms=41,
            input_snapshot=_snap(url="/SmartData/smartdata/records/sensordata",
                                 smartdataurl="/SmartData",
                                 requestmethod="GET")),
        run(job=j["aggregate"], step=1, chain=A, runid=A1, parent=A0,
            runstate="finished", result=AGG_RESULT_OK, at_minutes=1,
            durationms=63,
            input_snapshot=_snap(prejobinfo={"id": j["sensor"]},
                                 url="/SmartData/smartdata/records/sensordata",
                                 smartdataurl="/SmartData",
                                 requestmethod="GET")),
        run(job=j["store"], step=2, chain=A, runid=A2, parent=A1,
            runstate="finished", result=STORE_RESULT_OK, at_minutes=2,
            durationms=58, resultvaliduntil=ts(2).replace("+00:00", "Z"),
            input_snapshot=_snap(prejobinfo={"id": j["aggregate"],
                                             "records": AGG_RESULT_OK["records"]},
                                 prejobfield="records", requestmethod="POST",
                                 storage="smartmonitoring",
                                 collection="datajobs_log")),
        run(job=j["publish"], step=3, chain=A, runid=A3, parent=A2,
            runstate="finished", result=PUBLISH_RESULT_OK, at_minutes=3,
            durationms=47, resultreused=True, inputfromrunid=A2,
            input_snapshot=_snap(prejobinfo={"id": j["store"],
                                             "records": AGG_RESULT_OK["records"]},
                                 prejobfield="records", requestmethod="POST")),
    ]

    # ================================================================
    # Chain run B — the interesting one: store failed at step 2.
    # Steps 0 and 1 finished, the chain stopped there (onerror=skip on
    # the aggregate->store edge). Seed logging shows the compensation
    # hop (store -> cleanup, onerror=run) fired.
    # Resume point: step 2 (store). Replay plan: skip 0/1, re-execute 2.
    # ================================================================
    B = rid("chainrun-B")
    B0 = rid("B-step0")
    B1 = rid("B-step1")
    B2 = rid("B-step2")
    rows += [
        run(job=j["sensor"], step=0, chain=B, runid=B0, parent=None,
            runstate="finished", result=SENSOR_RESULT_OK, at_minutes=30,
            durationms=39,
            input_snapshot=_snap(url="/SmartData/smartdata/records/sensordata",
                                 smartdataurl="/SmartData",
                                 requestmethod="GET")),
        run(job=j["aggregate"], step=1, chain=B, runid=B1, parent=B0,
            runstate="finished", result=AGG_RESULT_OK, at_minutes=31,
            durationms=61,
            input_snapshot=_snap(prejobinfo={"id": j["sensor"]},
                                 url="/SmartData/smartdata/records/sensordata",
                                 requestmethod="GET")),
        run(job=j["store"], step=2, chain=B, runid=B2, parent=B1,
            runstate="failed", result=STORE_RESULT_FAIL, at_minutes=32,
            errorclass="http_5xx", durationms=41,
            input_snapshot=_snap(prejobinfo={"id": j["aggregate"],
                                             "records": AGG_RESULT_OK["records"]},
                                 prejobfield="records", requestmethod="POST",
                                 storage="smartmonitoring",
                                 collection="datajobs_log")),
    ]

    # ================================================================
    # Chain run C — chain run B after the compensated retry already
    # happened once: store was replayed in the same chain run, the retry
    # failed again with a timeout. Demonstrates replayofrunid/replayreason
    # and attempt tracking inside one chain run.
    # ================================================================
    C = B  # same logical chain run (a replay resumes inside the chain run)
    C2 = rid("C-step2-replay")
    rows.append(
        run(job=j["store"], step=2, chain=C, runid=C2, parent=B1,
            runstate="timeout", at_minutes=45, attempt=2,
            result={"saveMethod": "WriteDataAction/HTTP URL connection",
                    "statemsg": "HttpTimeoutException: request timed out",
                    "state": "failed", "call_time_ms": 5000},
            errorclass="timeout", durationms=5000,
            replayof=B2, replayreason="manual resume after archive 500",
            input_snapshot=_snap(prejobinfo={"id": j["aggregate"],
                                             "records": AGG_RESULT_OK["records"]},
                                 prejobfield="records", requestmethod="POST",
                                 storage="smartmonitoring",
                                 collection="datajobs_log")),
    )

    # ================================================================
    # Chain run D — reachability check failed at the root, onerror=fail
    # stops the chain run. Nothing follows. Replay plan: re-execute 0.
    # ================================================================
    D = rid("chainrun-D")
    D0 = rid("D-step0")
    rows.append(
        run(job=j["checknet"], step=0, chain=D, runid=D0, parent=None,
            runstate="failed", result=CHECKNET_FAIL, at_minutes=60,
            errorclass="http_5xx", durationms=1204,
            input_snapshot=_snap(url="/SmartData/smartdata/system/info",
                                 requestmethod="GET", statuscode=200)),
    )

    # ================================================================
    # Chain run E — reachability recovered, pull ran, cleanup ran below.
    # ================================================================
    E = rid("chainrun-E")
    E0 = rid("E-step0")
    E1 = rid("E-step1")
    E2 = rid("E-step2")
    rows += [
        run(job=j["checknet"], step=0, chain=E, runid=E0, parent=None,
            runstate="finished", result=CHECKNET_OK, at_minutes=90,
            durationms=87,
            input_snapshot=_snap(url="/SmartData/smartdata/system/info",
                                 requestmethod="GET", statuscode=200)),
        run(job=j["pull"], step=1, chain=E, runid=E1, parent=E0,
            runstate="finished", at_minutes=91, durationms=230,
            result={"state": "finished", "httpStatus": 200,
                    "records": [{"id": 11, "ts": "2026-11-25T22:00:00",
                                 "temp1": 17.9, "synced": False},
                                {"id": 12, "ts": "2026-11-25T22:15:00",
                                 "temp1": 18.0, "synced": False}],
                    "usedTime_ms": 230},
            input_snapshot=_snap(prejobinfo={"id": j["checknet"]},
                                 url="/SmartData/smartdata/records/testcollection_ts",
                                 smartdataurl="/SmartData",
                                 requestmethod="GET")),
        run(job=j["cleanup"], step=2, chain=E, runid=E2, parent=E1,
            runstate="finished", result=CLEANUP_RESULT_OK, at_minutes=92,
            durationms=340,
            input_snapshot=_snap(prejobinfo={"id": j["pull"]},
                                 storage=STORAGE, collection="datajobs_log",
                                 days=14, filter="processed,eq,true")),
    ]

    # ================================================================
    # Chain run F — maxchaindepth guard: the self-loop was cut after
    # step 2. Step 1 is 'skipped' (never executed: the guard fired before
    # the successor was scheduled). The plan then has no resume point
    # other than the skipped run.
    # ================================================================
    F = rid("chainrun-F")
    F0 = rid("F-step0")
    rows.append(
        run(job=j["loop"], step=0, chain=F, runid=F0, parent=None,
            runstate="finished", result=SENSOR_RESULT_OK, at_minutes=120,
            durationms=44,
            input_snapshot=_snap(url="/SmartData/smartdata/records/sensordata")),
    )

    # ================================================================
    # Standalone root run of the cleanup job, not part of any chain.
    # Shows a root run whose chainrunid equals its runid.
    # ================================================================
    G = rid("chainrun-G")
    rows.append(
        run(job=j["cleanup"], step=0, chain=G, runid=G, parent=None,
            runstate="finished", result=dict(CLEANUP_RESULT_OK,
                                             deleteResult={
                                                 "cutoffDate": "2026-11-12",
                                                 "deletedCount": 0,
                                                 "success": True}),
            at_minutes=150, durationms=96,
            input_snapshot=_snap(storage=STORAGE, collection="datajobs_log",
                                 days=14, filter="processed,eq,true")),
    )

    # ================================================================
    # A failed run that holds a *stale* reusable result: chain run H did
    # aggregate successfully 6 h earlier, its statement of validity has
    # expired (resultvaliduntil in the past), so a resume may not skip it.
    # ================================================================
    H = rid("chainrun-H")
    H0 = rid("H-step0")
    H1 = rid("H-step1")
    rows += [
        run(job=j["sensor"], step=0, chain=H, runid=H0, parent=None,
            runstate="finished", result=SENSOR_RESULT_OK, at_minutes=-360,
            durationms=38,
            resultvaliduntil=ts(-360 + 15).replace("+00:00", "Z"),
            input_snapshot=_snap(url="/SmartData/smartdata/records/sensordata")),
        run(job=j["aggregate"], step=1, chain=H, runid=H1, parent=H0,
            runstate="finished", result=AGG_RESULT_OK, at_minutes=-359,
            durationms=59,
            resultvaliduntil=ts(-359 + 60).replace("+00:00", "Z"),
            input_snapshot=_snap(prejobinfo={"id": j["sensor"]})),
    ]
    return rows


# --------------------------------------------------------------------------
# Install / remove
# --------------------------------------------------------------------------
def existing_demo_jobs():
    """Returns the installed demo jobs.

    Filtered client side on purpose: the SmartData filter operators are not
    reliable for varchar columns (name,like,... and name,starts,... return
    all rows), so a server-side filter must never decide what gets deleted.
    """
    status, body = records("datajobs", size=500, attributes="id,name")
    if status != 200:
        raise SystemExit("Reading datajobs failed (%s): %s" % (status, body))
    return [r for r in body.get("records", [])
            if str(r.get("name", "")).startswith(PREFIX)]


def remove_demo(dry):
    demo = existing_demo_jobs()
    if not demo:
        print("no demo jobs present")
        return
    ids = sorted(int(r["id"]) for r in demo)
    print("removing %d demo job(s): ids %s" % (len(ids), ids))
    if dry:
        return

    # Deleted over psql with an explicit id list, never through a REST filter.
    # SmartData's filter operators silently return all rows for varchar
    # columns (see existing_demo_jobs()), and a DELETE that ignores its
    # filter would wipe every job in the storage. An explicit
    # "id IN (...)" built from the names we checked is the only safe form.
    idlist = ", ".join(str(i) for i in ids)
    # Rows that reference a demo job by id, in dependency order.
    statements = [
        "DELETE FROM %s.datajobs_log WHERE datajob_id IN (%s)" % (STORAGE, idlist),
        "DELETE FROM %s.datajobs_join_oo WHERE datajob_id IN (%s)" % (STORAGE, idlist),
        "DELETE FROM %s.datajobs_params WHERE datajob_id IN (%s)" % (STORAGE, idlist),
        ("DELETE FROM %s.datajobs_chain WHERE pre_job_id IN (%s) "
         "OR post_job_id IN (%s)" % (STORAGE, idlist, idlist)),
        # A final re-check: abort the whole transaction if a row that is not
        # one of ours would be affected.
        ("DO $$ BEGIN IF EXISTS (SELECT 1 FROM %s.datajobs WHERE id IN (%s) "
         "AND name NOT LIKE %s) THEN RAISE EXCEPTION "
         "'refusing to delete a job that is not demo data'; END IF; END $$;"
         % (STORAGE, idlist, sql_literal(PREFIX + "%"))),
        "DELETE FROM %s.datajobs WHERE id IN (%s)" % (STORAGE, idlist),
    ]
    # Every statement needs its own terminator: a DO $$...$$ block is not
    # closed by the keyword COMMIT following it.
    psql("BEGIN;\n" + "\n".join(st + ";" for st in statements) + "\nCOMMIT;",
         dry=False)
    print("removed %d jobs and their params, chain edges, runs and links"
          % len(ids))


# --------------------------------------------------------------------------
# Direct database access for the run log
# --------------------------------------------------------------------------
DB_HOST = os.environ.get("SMARTUSER_DB_HOST", "frodermann.me")
DB_PORT = os.environ.get("SMARTUSER_DB_PORT", "5432")
DB_NAME = os.environ.get("SMARTDATA_DB_NAME", "smartmonitoring_test")
DB_USER = os.environ.get("SMARTUSER_DB_USER", "webengineering_group")
DB_PASSWORD = os.environ.get("SMARTUSER_DB_PASSWORD", "")


def sql_literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def psql(sql, dry):
    """Runs sql through psql. Password comes from the environment, never argv."""
    env = dict(os.environ, PGPASSWORD=DB_PASSWORD, PGSSLMODE="require")
    cmd = ["psql", "-v", "ON_ERROR_STOP=1", "-q", "-t", "-A",
           "-h", DB_HOST, "-p", str(DB_PORT), "-U", DB_USER, "-d", DB_NAME,
           "-c", sql]
    if dry:
        print("  psql -d %s: %s" % (DB_NAME, sql[:160] + ("..." if len(sql) > 160 else "")))
        return ""
    res = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if res.returncode != 0:
        raise SystemExit("psql failed: %s" % (res.stderr.strip() or res.stdout.strip()))
    return res.stdout.strip()


def psql_insert_runs(runs):
    columns = ["datajob_id", "result", "ts", "iserror", "wastimeout", "processed",
               "runid", "chainrunid", "parentrunid", "step", "runstate", "input",
               "inputhash", "errorclass", "attempt", "replayofrunid",
               "replayreason", "resultvaliduntil", "resultreused",
               "inputfromrunid", "durationms"]
    values = []
    for row in runs:
        parts = []
        for col in columns:
            val = row.get(col)
            if val is None:
                parts.append("NULL")
            elif isinstance(val, bool):
                parts.append("TRUE" if val else "FALSE")
            elif isinstance(val, (int, float)):
                parts.append(str(val))
            else:
                parts.append(sql_literal(val))
        values.append("(" + ", ".join(parts) + ")")
    sql = ('INSERT INTO %s.datajobs_log (%s) VALUES\n%s;'
           % (STORAGE, ", ".join(columns), ",\n".join(values)))
    psql(sql, dry=False)


def install(dry):
    remove_demo(dry)

    payload = demo_jobs()
    ids = {}
    if dry:
        print("would create jobs:")
        for job in payload:
            print("  %-28s %-16s %s" % (job["name"], job["action"], job["desc"]))
        print("would create %d chain edges and %d runs"
              % (len(demo_chains()), 16))
        return

    # ---- jobs ----
    rows = []
    for job in payload:
        defs = {"name": job["name"], "desc": job["desc"],
                "action": job["action"], "active": False,
                "priority": job["priority"],
                "idempotent": job["idempotent"],
                "reusable": job["reusable"],
                "resultttlsecs": job["resultttlsecs"],
                "resultttlbasis": job["resultttlbasis"],
                "resultscope": job["resultscope"],
                "maxchaindepth": job["maxchaindepth"]}
        rows.append(defs)
    created_ids = create("datajobs", rows)
    if isinstance(created_ids, list) and len(created_ids) == len(rows):
        for job, new_id in zip(payload, created_ids):
            ids[job["slug"]] = int(new_id)
    else:  # fall back to a name lookup
        for row in existing_demo_jobs():
            for job in payload:
                if row["name"] == job["name"]:
                    ids[job["slug"]] = row["id"]
    print("created %d jobs: %s" % (len(ids), json.dumps(ids)))

    # ---- params ----
    param_rows = []
    for job in payload:
        for key, value, ptype in job["params"]:
            param_rows.append({"key": key, "value": value,
                               "datajob_id": ids[job["slug"]],
                               "type": ptype})
    status, body = call("POST", "/smartdata/records/datajobs_params",
                        {"storage": STORAGE}, param_rows)
    if status != 201:
        raise SystemExit("Creating datajobs_params failed (%s): %s" % (status, body))
    print("created %d params" % len(param_rows))

    # ---- chain edges ----
    edge_rows = []
    for pre, post, attrs in demo_chains():
        if pre not in ids or post not in ids:
            continue
        row = {"pre_job_id": ids[pre], "post_job_id": ids[post]}
        row.update(attrs)
        edge_rows.append(row)
    status, body = call("POST", "/smartdata/records/datajobs_chain",
                        {"storage": STORAGE}, edge_rows)
    if status != 201:
        raise SystemExit("Creating datajobs_chain failed (%s): %s" % (status, body))
    print("created %d chain edges" % len(edge_rows))

    # ---- object links (the pinning the UI uses) ----
    try:
        st, objs = records("tbl_observedobject", size=1)
        oo_id = objs["records"][0]["id"]
        link_rows = [{"datajob_id": job_id, "oo_id": oo_id}
                     for job_id in ids.values()]
        status, body = call("POST", "/smartdata/records/datajobs_join_oo",
                            {"storage": STORAGE}, link_rows)
        if status == 201:
            print("linked %d jobs to observed object %s" % (len(link_rows), oo_id))
    except Exception as ex:  # links are cosmetic for the demo
        print("skipped object links: %s" % ex)

    # ---- runs (psql: uuid columns are not writable over REST) ----
    runs = demo_runs(ids)
    psql_insert_runs(runs)
    print("created %d runs" % len(runs))

    # ---- summary ----
    print()
    print("Demo chain runs (use these with /jobexecution/replay):")
    for ran in runs:
        if ran["step"] == 0:
            print("  chainrunid %s  root job %s" % (ran["chainrunid"],
                                                   ran["datajob_id"]))
    print()
    print("Try:")
    print("  curl 'http://localhost:8080/SmartDataJobs/smartdatajobs/jobexecution/replay"
          "?storage=%s&chainrunid=%s'" % (STORAGE, rid("chainrun-B")))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dryrun", action="store_true")
    ap.add_argument("--remove", action="store_true",
                    help="delete the demo rows and exit")
    args = ap.parse_args()

    status, info = call("GET", "/smartdata/system/info")
    if status != 200:
        raise SystemExit("SmartData not reachable at %s (%s)" % (SMARTDATA, status))

    if args.remove:
        remove_demo(args.dryrun)
    else:
        install(args.dryrun)


if __name__ == "__main__":
    sys.exit(main())
