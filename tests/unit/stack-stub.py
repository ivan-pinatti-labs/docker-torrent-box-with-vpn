#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
"""Stand in for the stack, for the shell tests of the rotation and wiring scripts.

One program answering as podman, podman-compose, jq, yq, xmlstarlet, openssl
and timeout, picked by the name it is run as (the tests link each name to it
in a stub directory first on PATH). Nothing it does leaves the test's own
state directory, named by STUB_STATE.

Every call is appended to <state>/log as one line: the name, then the
arguments joined by spaces, with a newline inside an argument written as
\\n. The tests read that log to check the calls a real run would make.

Before anything else, a call is matched against the rules in <state>/rules,
newest first, so a test can override what its setup wrote. A rule is a file
whose first line is a regular expression searched for in the logged line,
the second the exit status, the third how many calls it answers (`-` for
every one), and the rest the standard output. The newest rule that matches
answers the call, and one that has answered its last call is set aside. A
call no rule matches gets the default below:

podman keeps a small model of the containers: <state>/containers lists the
ones that exist and <state>/stopped the ones not running. `container exists`,
`container inspect` and `inspect` answer from it, `stop` and `start` change
it, `run` builds the scratch Calibre-Web database the wiring script asks the
real image for, and `exec` succeeds silently. jq runs the filters the
scripts use, each one written out below in Python rather than interpreted,
so a filter the table does not know is an error. yq reads and assigns paths
in a file holding JSON (which is YAML too). xmlstarlet sets one element of an
XML file, unless <state>/xmlstarlet-noop exists. openssl prints a new 32
character key each call, numbered from 0001. timeout runs the rest of its
command line, and podman-compose succeeds.

Usage: <name> [<argument> ...], with STUB_STATE set.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import sqlite3
import sys
from pathlib import Path

STATE = Path(os.environ["STUB_STATE"])


def log_line(name: str, args: list[str]) -> str:
    """The call as the log records it and the rules match it."""
    return " ".join([name, *args]).replace("\n", "\\n")


def lines_of(path: Path) -> list[str]:
    """The non empty lines of a state file, or none when it is missing."""
    if not path.exists():
        return []
    return [line for line in path.read_text().splitlines() if line]


def answer_from_rules(line: str) -> tuple[int, str] | None:
    """The exit status and output of the newest rule matching `line`, if any."""
    rules = STATE / "rules"
    if not rules.is_dir():
        return None
    for rule in sorted(rules.iterdir(), reverse=True):
        if rule.suffix == ".used":
            continue
        pattern, status, times, body = rule.read_text().split("\n", 3)
        if not re.search(pattern, line):
            continue
        if times != "-":
            left = int(times) - 1
            if left == 0:
                rule.rename(rule.with_suffix(".used"))
            else:
                rule.write_text(f"{pattern}\n{status}\n{left}\n{body}")
        return int(status), body
    return None


# ---------------------------------------------------------------------------
# podman
# ---------------------------------------------------------------------------


def set_stopped(names: list[str], stopped: bool) -> None:
    current = lines_of(STATE / "stopped")
    for name in names:
        if stopped and name not in current:
            current.append(name)
        if not stopped and name in current:
            current.remove(name)
    (STATE / "stopped").write_text("".join(f"{n}\n" for n in current))


def fresh_calibre_web_db(args: list[str]) -> None:
    """What `ub.init_db` in the Calibre-Web image writes: an admin and Guest."""
    volume = args[args.index("-v") + 1]
    host = volume.split(":")[0]
    conn = sqlite3.connect(Path(host) / "fresh_app.db")
    conn.execute(
        "CREATE TABLE user (id INTEGER PRIMARY KEY, name TEXT, role INTEGER, password TEXT)"
    )
    conn.executemany(
        "INSERT INTO user VALUES (?, ?, ?, ?)",
        [(1, "admin", 1, "hash"), (2, "Guest", 32, "")],
    )
    conn.commit()
    conn.close()


def podman(args: list[str]) -> int:
    existing = lines_of(STATE / "containers")
    stopped = lines_of(STATE / "stopped")
    if args[:2] == ["container", "exists"]:
        return 0 if args[2] in existing else 1
    if args[:2] == ["container", "inspect"]:
        name = args[-1]
        if name not in existing:
            return 125
        print("false" if name in stopped else "true")
        return 0
    if args[0] == "inspect":
        name = args[-1]
        health = STATE / "health" / name
        print(health.read_text().strip() if health.exists() else "none")
        return 0
    if args[0] == "stop":
        set_stopped(
            [a for a in args[1:] if not a.startswith("--") and not a.isdigit()], True
        )
        return 0
    if args[0] == "start":
        set_stopped(args[1:], False)
        return 0
    if args[0] == "run":
        fresh_calibre_web_db(args)
        return 0
    return 0


# ---------------------------------------------------------------------------
# jq
# ---------------------------------------------------------------------------


def first_where(key: str, value: object):
    """`map(select(.<key> == value)) | first`, null when nothing matches."""
    return lambda doc, _a: [next((x for x in doc if x.get(key) == value), None)]


def map_fields(doc: dict, values: dict) -> dict:
    """`.fields |= map(if .name == k then .value = v ... else . end)`."""
    doc = dict(doc)
    fields = []
    for field in doc.get("fields", []):
        field = dict(field)
        name = field.get("name", "")
        for key, value in values.items():
            if key == name or (callable(key) and key(name)):
                field["value"] = value
                break
        fields.append(field)
    doc["fields"] = fields
    return doc


def category(name: str) -> bool:
    """`(.name | test("Category$")) and ((.name | test("Imported")) | not)`."""
    return name.endswith("Category") and "Imported" not in name


def set_keys(doc: dict, **values) -> dict:
    doc = dict(doc)
    doc.update(values)
    return doc


def field_value(name: str):
    return lambda doc, _a: [f["value"] for f in doc["fields"] if f["name"] == name]


def jellyfin_connection(doc: dict, a: dict) -> list:
    doc = map_fields(
        set_keys(doc, name="Emby / Jellyfin"),
        {
            "host": a["host"],
            "port": int(a["port"]),
            "useSsl": False,
            "urlBase": a["url_base"],
            "apiKey": a["key"],
            "updateLibrary": True,
        },
    )
    for event in ("Download", "ImportComplete", "ReleaseImport", "Upgrade", "Rename"):
        if doc.get(f"supportsOn{event}"):
            doc[f"on{event}"] = True
    return [doc]


def prowlarr_indexers(doc: list, _a: dict) -> list:
    """`.[] | select(.fields[]? | .name == "baseUrl" and (.value | test(...)))`."""
    pattern = re.compile("://prowlarr[:/]")
    return [
        rec
        for rec in doc
        for field in rec.get("fields") or []
        if field.get("name") == "baseUrl" and pattern.search(field.get("value", ""))
    ]


def indexer_payload(doc: dict, a: dict) -> list:
    doc = set_keys(doc, appProfileId=1, enable=False)
    doc["fields"] = [f for f in doc["fields"] if f["name"] != "baseUrl"] + [
        {"name": "baseUrl", "value": a["baseUrl"]}
    ]
    return [doc]


def arr_password(doc: dict, a: dict) -> list:
    user = doc.get("username") or ""
    return [
        set_keys(
            doc,
            username=user or a["user"],
            password=a["pw"],
            passwordConfirmation=a["pw"],
        )
    ]


def index_of(doc: dict, a: dict) -> list:
    tags = doc["tags"]
    return [tags.index(a["t"]) if a["t"] in tags else None]


FILTERS = {
    ".": lambda d, a: [d],
    ".id": lambda d, a: [d.get("id")],
    ".name": lambda d, a: [d.get("name")],
    ".username": lambda d, a: [d.get("username")],
    ".isInit": lambda d, a: [d.get("isInit")],
    ".user.id": lambda d, a: [d["user"]["id"]],
    ".apiKey.apiKey": lambda d, a: [d["apiKey"]["apiKey"]],
    ".BaseUrl": lambda d, a: [d.get("BaseUrl")],
    ".metadataSource": lambda d, a: [d.get("metadataSource")],
    ".StartupWizardCompleted": lambda d, a: [d.get("StartupWizardCompleted")],
    "length": lambda d, a: [len(d)],
    ".id // empty": lambda d, a: [d["id"]] if d.get("id") not in (None, False) else [],
    ".AccessToken // empty": lambda d, a: (
        [d["AccessToken"]] if d.get("AccessToken") else []
    ),
    ".user.token // empty": lambda d, a: (
        [d["user"]["token"]] if (d.get("user") or {}).get("token") else []
    ),
    'has("StartupWizardCompleted")': lambda d, a: [
        isinstance(d, dict) and "StartupWizardCompleted" in d
    ],
    ".Items[].AccessToken": lambda d, a: [i["AccessToken"] for i in d["Items"]],
    ".Items | sort_by(.DateCreated) | last.AccessToken": lambda d, a: [
        sorted(d["Items"], key=lambda i: i["DateCreated"])[-1]["AccessToken"]
    ],
    "[.Items[] | select(.AccessToken != $old)] | sort_by(.DateCreated) | last.AccessToken": lambda d, a: [
        (
            sorted(
                (i for i in d["Items"] if i["AccessToken"] != a["old"]),
                key=lambda i: i["DateCreated"],
            )
            or [{}]
        )[-1].get("AccessToken")
    ],
    ".[] | select(.Name == $name) | .Id": lambda d, a: [
        u["Id"] for u in d if u["Name"] == a["name"]
    ],
    '.apiKeys[] | select(.name == "wire-connections")': lambda d, a: [
        k for k in d["apiKeys"] if k["name"] == "wire-connections"
    ],
    '{name: "wire-connections", userId: $userId, isActive: true}': lambda d, a: [
        {"name": "wire-connections", "userId": a["userId"], "isActive": True}
    ],
    "{label: $label}": lambda d, a: [{"label": a["label"]}],
    "map(select(.name == $name)) | first": lambda d, a: first_where("name", a["name"])(
        d, a
    ),
    "map(select(.implementation == $impl)) | first": lambda d, a: first_where(
        "implementation", a["impl"]
    )(d, a),
    "map(select(.definitionName == $def)) | first": lambda d, a: first_where(
        "definitionName", a["def"]
    )(d, a),
    'map(select(.implementation == "QBittorrent")) | first': first_where(
        "implementation", "QBittorrent"
    ),
    'map(select(.implementation == "Sabnzbd")) | first': first_where(
        "implementation", "Sabnzbd"
    ),
    'map(select(.implementation == "MediaBrowser")) | first': first_where(
        "implementation", "MediaBrowser"
    ),
    'map(select(.implementation == "FlareSolverr")) | first': first_where(
        "implementation", "FlareSolverr"
    ),
    "any(.[]; .name == $name and .enable)": lambda d, a: [
        any(x["name"] == a["name"] and x["enable"] for x in d)
    ],
    '.fields[] | select(.name == "host") | .value': field_value("host"),
    '.fields[] | select(.name == "port") | .value': field_value("port"),
    ".tags | index($t)": index_of,
    ".tags += [$t]": lambda d, a: [set_keys(d, tags=[*d["tags"], a["t"]])],
    ".enable = true": lambda d, a: [set_keys(d, enable=True)],
    ".BaseUrl = $baseUrl": lambda d, a: [set_keys(d, BaseUrl=a["baseUrl"])],
    ".metadataSource = $source": lambda d, a: [set_keys(d, metadataSource=a["source"])],
    '.fields[] |= if .name == "apiKey" then .value = $key else . end': lambda d, a: [
        map_fields(d, {"apiKey": a["key"]})
    ],
    '.fields |= map(if .name == "apiKey" then .value = $key else . end)': lambda d, a: [
        map_fields(d, {"apiKey": a["key"]})
    ],
    '.fields |= map( if .name == "host" then .value = $host elif .name == "port" then .value = ($port | tonumber) '
    "else . end)": lambda d, a: [
        map_fields(d, {"host": a["host"], "port": int(a["port"])})
    ],
    ".username = $cred | .password = $cred | .passwordConfirmation = $cred | .certificateValidation = "
    '"disabledForLocalAddresses"': lambda d, a: [
        set_keys(
            d,
            username=a["cred"],
            password=a["cred"],
            passwordConfirmation=a["cred"],
            certificateValidation="disabledForLocalAddresses",
        )
    ],
    '.name = "QBittorrent" | .enable = true | .fields |= map( if .name == "host" then .value = $host elif .name == '
    '"port" then .value = ($port | tonumber) elif .name == "useSsl" then .value = true elif .name == "username" then '
    '.value = $username elif .name == "password" then .value = $password elif (.name | test("Category$")) and '
    '((.name | test("Imported")) | not) then .value = $category else . end)': lambda d, a: [
        map_fields(
            set_keys(d, name="QBittorrent", enable=True),
            {
                "host": a["host"],
                "port": int(a["port"]),
                "useSsl": True,
                "username": a["username"],
                "password": a["password"],
                category: a["category"],
            },
        )
    ],
    '.name = "SABnzbd" | .enable = true | .fields |= map( if .name == "host" then .value = $host elif .name == '
    '"port" then .value = ($port | tonumber) elif .name == "useSsl" then .value = false elif .name == "urlBase" then '
    '.value = $urlBase elif .name == "apiKey" then .value = $apiKey elif (.name | test("Category$")) and ((.name | '
    'test("Imported")) | not) then .value = $category else . end)': lambda d, a: [
        map_fields(
            set_keys(d, name="SABnzbd", enable=True),
            {
                "host": a["host"],
                "port": int(a["port"]),
                "useSsl": False,
                "urlBase": a["urlBase"],
                "apiKey": a["apiKey"],
                category: a["category"],
            },
        )
    ],
    '.name = "Emby / Jellyfin" | .fields |= map( if .name == "host" then .value = $host elif .name == "port" then '
    '.value = ($port | tonumber) elif .name == "useSsl" then .value = false elif .name == "urlBase" then .value = '
    '$url_base elif .name == "apiKey" then .value = $key elif .name == "updateLibrary" then .value = true else . end) '
    "| (if .supportsOnDownload then .onDownload = true else . end) | (if .supportsOnImportComplete then "
    ".onImportComplete = true else . end) | (if .supportsOnReleaseImport then .onReleaseImport = true else . end) | "
    "(if .supportsOnUpgrade then .onUpgrade = true else . end) | (if .supportsOnRename then .onRename = true else . "
    "end)": jellyfin_connection,
    '.name = "FlareSolverr" | .tags = $tags | .fields |= map(if .name == "host" then .value = $host else . end)': (
        lambda d, a: [
            map_fields(
                set_keys(d, name="FlareSolverr", tags=a["tags"]), {"host": a["host"]}
            )
        ]
    ),
    '.appProfileId = 1 | .enable = false | .fields |= (map(select(.name != "baseUrl")) + [{"name": "baseUrl", '
    '"value": $baseUrl}])': indexer_payload,
    '.name = $name | .syncLevel = "fullSync" | .fields |= map( if .name == "prowlarrUrl" then .value = $prowlarrUrl '
    'elif .name == "baseUrl" then .value = $baseUrl elif .name == "apiKey" then .value = $apiKey else . end)': (
        lambda d, a: [
            map_fields(
                set_keys(d, name=a["name"], syncLevel="fullSync"),
                {
                    "prowlarrUrl": a["prowlarrUrl"],
                    "baseUrl": a["baseUrl"],
                    "apiKey": a["apiKey"],
                },
            )
        ]
    ),
    '.[] | select(.fields[]? | .name == "baseUrl" and (.value | test("://prowlarr[:/]")))': prowlarr_indexers,
    '.username = (if ((.username // "") | length) == 0 then $user else .username end) | .password = $pw | '
    ".passwordConfirmation = $pw": arr_password,
}


def json_values(text: str) -> list:
    """Every JSON value in `text`, the way jq reads a stream of them."""
    decoder = json.JSONDecoder()
    values, pos = [], 0
    while True:
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos == len(text):
            return values
        value, pos = decoder.raw_decode(text, pos)
        values.append(value)


def jq(args: list[str]) -> int:
    raw = compact = exit_status = null_input = False
    named: dict[str, object] = {}
    program = None
    rest = list(args)
    while rest:
        arg = rest.pop(0)
        if arg in ("--arg", "--argjson"):
            name, value = rest.pop(0), rest.pop(0)
            named[name] = value if arg == "--arg" else json.loads(value)
        elif arg.startswith("-") and len(arg) > 1:
            raw |= "r" in arg
            compact |= "c" in arg
            exit_status |= "e" in arg
            null_input |= "n" in arg
        else:
            program = arg
    program = " ".join(program.split())
    if program not in FILTERS:
        print(f"jq stub: no filter {program!r}", file=sys.stderr)
        return 3
    try:
        inputs = [None] if null_input else json_values(sys.stdin.read())
    except ValueError as error:
        print(f"jq: error: {error}", file=sys.stderr)
        return 2
    results = []
    try:
        for value in inputs:
            results.extend(FILTERS[program](value, named))
    except (KeyError, TypeError, AttributeError, IndexError) as error:
        print(f"jq: error: {error!r}", file=sys.stderr)
        return 5
    for result in results:
        if raw and isinstance(result, str):
            print(result)
        elif compact:
            print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))
        else:
            print(json.dumps(result, indent=2, ensure_ascii=False))
    if exit_status:
        if not results:
            return 4
        return 1 if results[-1] in (None, False) else 0
    return 0


# ---------------------------------------------------------------------------
# yq, xmlstarlet, openssl
# ---------------------------------------------------------------------------


def yq_path(path: str) -> list:
    """`.a.b[0].c` as ["a", "b", 0, "c"]."""
    keys: list = []
    for part in path.strip("()").lstrip(".").split("."):
        match = re.fullmatch(r"(\w+)((?:\[\d+\])*)", part)
        keys.append(match.group(1))
        keys.extend(int(i) for i in re.findall(r"\[(\d+)\]", match.group(2)))
    return keys


def yq(args: list[str]) -> int:
    in_place = "-i" in args
    expression, file = [a for a in args if a not in ("-i", "-r")]
    doc = json.loads(Path(file).read_text())
    assignment = re.fullmatch(r"(\S+) = (.+)", expression)
    if assignment:
        *parents, last = yq_path(assignment.group(1))
        value = assignment.group(2)
        env = re.fullmatch(r"strenv\((\w+)\)", value)
        value = os.environ[env.group(1)] if env else json.loads(value)
        node = doc
        for key in parents:
            node = node.setdefault(key, {}) if isinstance(key, str) else node[key]
        node[last] = value
        if in_place:
            Path(file).write_text(json.dumps(doc, indent=2) + "\n")
        return 0
    path, _, default = expression.partition(" // ")
    node = doc
    for key in yq_path(path):
        node = node.get(key) if isinstance(node, dict) else None
    if node is None:
        node = json.loads(default) if default else None
    print(
        "null"
        if node is None
        else str(node).lower()
        if isinstance(node, bool)
        else node
    )
    return 0


def xmlstarlet(args: list[str]) -> int:
    element = args[args.index("--update") + 1].rsplit("/", 1)[1]
    value = args[args.index("--value") + 1]
    if (STATE / "xmlstarlet-noop").exists():
        return 0
    path = Path(args[-1])
    path.write_text(
        re.sub(
            f"<{element}>[^<]*</{element}>",
            f"<{element}>{value}</{element}>",
            path.read_text(),
        )
    )
    return 0


def openssl(_args: list[str]) -> int:
    counter = STATE / "openssl-count"
    number = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(number))
    print(f"{number:04d}" + "f" * 28)
    return 0


TOOLS = {
    "podman": podman,
    "jq": jq,
    "yq": yq,
    "xmlstarlet": xmlstarlet,
    "openssl": openssl,
    "podman-compose": lambda _args: 0,
}


def main(argv: list[str]) -> int:
    name = Path(argv[0]).name
    args = argv[1:]
    if name == "timeout":
        # B606: runs the command the script handed timeout, as timeout does.
        os.execvp(args[1], args[1:])  # nosec B606
    # The lock is held only while the shared files change, never while jq or
    # yq reads standard input: in `podman exec ... | jq ...` the writer is
    # another stub, which has to get the lock to finish.
    with open(STATE / "lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        line = log_line(name, args)
        with open(STATE / "log", "a") as log:
            log.write(line + "\n")
        answer = answer_from_rules(line)
        if answer is None and name in ("podman", "openssl"):
            return TOOLS[name](args)
    if answer is None:
        return TOOLS[name](args)
    status, body = answer
    sys.stdout.write(body)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
