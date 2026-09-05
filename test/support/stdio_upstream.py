#!/usr/bin/env python3
"""A minimal MCP stdio fixture upstream for the Noizu.MCP.Engine test suite.

Speaks just enough JSON-RPC MCP for the engine's supervised sessions:

  * initialize / notifications/initialized
  * tools/list, tools/call (echo, fail, token, emit_change)
  * prompts/list, resources/list, resources/templates/list (empty)
  * ping
  * sql/schema + sql/scan when --advertise-sql

Options:
  --name NAME        serverInfo name (default "fixture")
  --tools SPEC       comma list from {echo, fail, token, emit_change}
  --advertise-sql    advertise capabilities.experimental.sql
  --die-after MS     kill -9 ourselves after MS milliseconds (tests reconnect)
  --change-adds TOOL after emitting a list_changed, add TOOL to tools/list
"""

import argparse
import json
import os
import signal
import sys
import threading


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--name", default="fixture")
    p.add_argument("--tools", default="echo")
    p.add_argument("--advertise-sql", action="store_true")
    p.add_argument("--die-after", type=int, default=0)
    p.add_argument("--change-adds", default=None)
    return p.parse_args()


ARGS = parse_args()
BASE_TOOLS = [t for t in ARGS.tools.split(",") if t]
EXTRA_TOOLS = []


def tool_defs():
    names = BASE_TOOLS + EXTRA_TOOLS
    defs = []

    if "echo" in names:
        defs.append({
            "name": "echo",
            "description": "Echo the message back",
            "inputSchema": {
                "type": "object",
                "properties": {"message": {"type": "string"}},
                "required": ["message"],
            },
        })

    if "fail" in names:
        defs.append({
            "name": "fail",
            "description": "Always returns an execution error",
            "inputSchema": {"type": "object", "properties": {}},
        })

    if "token" in names:
        defs.append({
            "name": "token",
            "description": "Returns the pass-through env token",
            "inputSchema": {"type": "object", "properties": {}},
        })

    if "emit_change" in names:
        defs.append({
            "name": "emit_change",
            "description": "Emits notifications/tools/list_changed",
            "inputSchema": {"type": "object", "properties": {}},
        })

    for extra in EXTRA_TOOLS:
        defs.append({
            "name": extra,
            "description": "Added after a list_changed",
            "inputSchema": {"type": "object", "properties": {}},
        })

    return defs


def text_result(text, is_error=False):
    return {
        "content": [{"type": "text", "text": text}],
        "isError": is_error,
    }


def call_tool(name, args):
    if name == "echo":
        return text_result(args.get("message", ""))
    if name == "fail":
        return text_result("it failed on purpose", is_error=True)
    if name == "token":
        return text_result(os.environ.get("MCP_PASSTHROUGH_TOKEN") or "no-token")
    if name == "emit_change":
        if ARGS.change_adds and ARGS.change_adds not in EXTRA_TOOLS:
            EXTRA_TOOLS.append(ARGS.change_adds)
        emit({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        return text_result("changed")
    return text_result("unknown tool", is_error=True)


SQL_RELATIONS = [{
    "name": "rows",
    "kind": "dataset",
    "columns": [
        {"name": "id", "type": "bigint", "nullable": False, "description": None},
        {"name": "label", "type": "text", "nullable": False, "description": None},
    ],
    "primary_key": ["id"],
    "qual_columns": ["id"],
    "required_quals": [],
    "sort": True,
    "limit": True,
    "writable": False,
}]

SQL_ROWS = [[1, "one"], [2, "two"], [3, "three"]]


def emit(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def respond(id, result):
    emit({"jsonrpc": "2.0", "id": id, "result": result})


def respond_error(id, code, message):
    emit({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})


def capabilities():
    caps = {"tools": {"listChanged": True}}
    if ARGS.advertise_sql:
        caps["experimental"] = {"sql": {"version": 1}}
    return caps


def handle(method, params, id):
    if method == "initialize":
        respond(id, {
            "protocolVersion": params.get("protocolVersion", "2025-11-25"),
            "capabilities": capabilities(),
            "serverInfo": {"name": ARGS.name, "version": "1.0.0"},
        })
    elif method == "tools/list":
        respond(id, {"tools": tool_defs()})
    elif method == "tools/call":
        respond(id, call_tool(params.get("name"), params.get("arguments") or {}))
    elif method == "prompts/list":
        respond(id, {"prompts": []})
    elif method == "resources/list":
        respond(id, {"resources": []})
    elif method == "resources/templates/list":
        respond(id, {"resourceTemplates": []})
    elif method == "ping":
        respond(id, {})
    elif method == "sql/schema":
        if ARGS.advertise_sql:
            respond(id, {"version": 1, "relations": SQL_RELATIONS})
        else:
            respond_error(id, -32601, "method not found")
    elif method == "sql/scan":
        if ARGS.advertise_sql:
            respond(id, {"columns": ["id", "label"],
                         "rows": SQL_ROWS,
                         "nextCursor": None})
        else:
            respond_error(id, -32601, "method not found")
    elif id is not None:
        respond_error(id, -32601, "method not found: " + method)


def maybe_die():
    if ARGS.die_after > 0:
        def die():
            os.kill(os.getpid(), signal.SIGKILL)

        threading.Timer(ARGS.die_after / 1000.0, die).start()


def main():
    maybe_die()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method = message.get("method")
        id = message.get("id")
        if method and not method.startswith("notifications/"):
            handle(method, message.get("params") or {}, id)
        # notifications are accepted and ignored (except side effects)


if __name__ == "__main__":
    main()
